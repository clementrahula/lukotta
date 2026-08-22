import Foundation

/// Opening an encrypted container that is a file rather than a drive.
///
/// A LUKS container made with `cryptsetup luksFormat container.img` is the
/// common case, and Windows' equivalent is a VHDX with BitLocker switched on
/// inside it. Both are ordinary files holding what a drive would hold.
///
/// macOS attaches the file and hands back a `/dev/diskN`, after which the scan,
/// the first-sector probe, the claim, the mount and the eject all work
/// unmodified. The engine also accepts a path, and this route is used instead
/// because the attach happens as the user: the root helper sees only a device
/// node, and a file name chosen at the keyboard never reaches it.
public enum DiskImage {

    public struct Attached: Equatable, Sendable {
        /// "/dev/disk6", the whole disk the image was attached as.
        public let device: String
        public let url: URL
        /// "disk6", which is how `diskutil` names it.
        public var identifier: String { (device as NSString).lastPathComponent }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// macOS would not attach it at all: not a disk image, or damaged.
        case notAnImage(String)
        /// Attached, but holding nothing this app can open.
        case nothingToOpen(String)
    }

    /// The device node out of `hdiutil attach -plist` output.
    ///
    /// The first entity is the whole disk; partitions follow. Only the whole
    /// disk is wanted, because the scan finds the partitions itself.
    public static func device(inAttachOutput plist: [String: Any]) -> String? {
        guard let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
            .filter { $0.hasPrefix("/dev/disk") }
        // The shortest is the whole disk: /dev/disk6 before /dev/disk6s1.
        return devices.min { $0.count < $1.count }
    }

    /// Attach without mounting anything.
    ///
    /// macOS mounts nothing. An NTFS volume it recognises would otherwise be
    /// mounted read-only without being asked, after which the engine cannot have
    /// the device.
    /// How long macOS is given to attach a file.
    ///
    /// Attaching is normally instant. It is not for a file on a slow or
    /// unreachable disk, such as a network share that has gone away, where the
    /// alternative to a timeout is a spinner that never stops.
    public static let attachTimeout: TimeInterval = 30

    public static func attach(_ url: URL, timeout: TimeInterval = attachTimeout) -> Result<
        Attached, Failure
    > {
        // Plain first. A raw image, which is what `dd` and cryptsetup produce
        // and the usual shape of a LUKS container, has no header for macOS to
        // recognise and attaches only when told what it is.
        //
        // Almost anything therefore attaches: a raw image is only bytes, so a
        // text file becomes a very small disk holding nothing. What matters is
        // what the disk contains, which is established afterwards by reading it.
        // A file holding nothing recognisable is detached again and reported as
        // unopenable.
        for arguments in [
            ["attach", "-nomount", "-plist", url.path],
            [
                "attach", "-nomount", "-plist", "-imagekey", "diskimage-class=CRawDiskImage",
                url.path,
            ],
        ] {
            let result = run(arguments, timeout: timeout)
            guard result.status == 0,
                let data = result.out.data(using: .utf8),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
                let device = device(inAttachOutput: plist)
            else { continue }
            return .success(Attached(device: device, url: url))
        }
        return .failure(.notAnImage(appString("macOS could not open this file as a disk image.")))
    }

    /// The whole attached disk as a drive, when it holds a container rather
    /// than a partition table.
    ///
    /// `cryptsetup luksFormat container.img` writes its header at the very
    /// start of the file and stops there: no partition table, so `diskutil`
    /// reports a disk with nothing on it and the ordinary scan finds nothing to
    /// list. The first sector is the only thing that says otherwise, and an
    /// attached image belongs to the user who attached it, so reading it needs
    /// no privilege.
    ///
    /// Returns nil for anything unrecognised, which keeps an unopenable file out
    /// of the list rather than listing it as unknown.
    public static func wholeDiskDrive(_ attached: Attached, url: URL) -> Drive? {
        guard let sector = BootSector.read(devicePath: attached.device) else { return nil }
        let kind: VolumeKind
        switch BootSector.identify(sector) {
        case .luks, .ext, .btrfs, .xfs: kind = .linux
        case .bitlocker, .ntfs, .exfat: kind = .microsoft
        case .unknown: return nil
        }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return Drive(
            id: attached.identifier,
            devicePath: attached.device,
            // The file's name without its extension, which is what the drive is
            // called in Finder afterwards.
            name: url.deletingPathExtension().lastPathComponent,
            sizeBytes: size ?? 0,
            connection: appString("Disk Image"),
            kind: kind,
            // The file it came from, so that a passphrase remembered for this
            // container is found again next time. The device it attaches as
            // changes on every attach.
            uuid: url.path)
    }

    @discardableResult
    public static func detach(_ device: String) -> Bool {
        // Forced: the eject that precedes this has already taken the filesystem
        // down, and a lingering reference would keep the image file locked.
        run(["detach", device, "-force"]).status == 0
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 30) -> (
        status: Int32, out: String
    ) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (1, "") }

        // The deadline is watched before the pipe is read, since reading to the
        // end would itself wait on a process that will not finish.
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (1, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Keeping container files in the drive list.
///
/// The decisions only, with no state and no interface, so that the two rules
/// can be stated and tested: a container the scan cannot see is reinserted, and
/// a container is removed when it is the thing being ejected.
public enum ImageList {

    /// A scan's results with the container rows the scan cannot produce.
    ///
    /// A container with no partition table is reported by `diskutil` as an empty
    /// disk, so no scan returns it. The row is made once, from the first sector,
    /// and reinserted whenever the list is rebuilt.
    public static func merge(found: [Drive], images: [String: Drive]) -> [Drive] {
        guard !images.isEmpty else { return found }
        let present = Set(found.map { DriveScanner.wholeDisk(of: $0.id) })
        return found + images.filter { !present.contains($0.key) }.values
    }

    /// Which containers should be detached, given the devices just ejected.
    ///
    /// Driven by what was ejected rather than by what is absent from the list. A
    /// container that has been opened and not yet mounted is absent from
    /// nothing, and detaching it because another drive was ejected would remove
    /// it from whoever just opened it.
    public static func detaching(devices: [String], images: [String: Drive]) -> [String] {
        let ejected = Set(
            devices.map { DriveScanner.wholeDisk(of: ($0 as NSString).lastPathComponent) })
        return images.keys.filter { ejected.contains($0) }.sorted()
    }
}

extension DiskImage {
    /// Which of these disks are still attached.
    ///
    /// A container file can disappear without notice, detached in Finder or
    /// carried away on a drive that was unplugged. The device node answers this,
    /// at the cost of one stat.
    public static func stillAttached(_ identifiers: Set<String>) -> Set<String> {
        identifiers.filter { FileManager.default.fileExists(atPath: "/dev/" + $0) }
    }
}

extension DiskImage {
    /// Which devices these image files are attached as, if any.
    ///
    /// For clearing up after a run that ended early. An image left attached
    /// makes the next run pass or fail for reasons of its own.
    public static func attachedDevices(forImages paths: Set<String>) -> [String] {
        let listing = run(["info"]).out
        var devices: [String] = []
        var path = ""
        for line in listing.components(separatedBy: .newlines) {
            if line.hasPrefix("image-path") {
                path = line.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("/dev/disk"), paths.contains(path) {
                let device = line.components(separatedBy: .whitespaces)[0]
                // The whole disk rather than its partitions: detaching it takes
                // the rest with it.
                if !device.dropFirst(9).contains("s") { devices.append(device) }
            }
        }
        return devices
    }
}

extension DiskImage {
    /// Let macOS mount this itself, and say where it put it.
    ///
    /// exFAT is read and written by macOS itself, so opening it here would take
    /// a local volume and serve it back as a network one. The attachment is
    /// handed over instead: `diskutil` mounts every volume on the disk that
    /// macOS understands, and it appears in Finder as an ordinary disk, ejected
    /// there like any other.
    ///
    /// Returns where it landed, or nil if macOS declined after all.
    public static func handToMacOS(device: String) -> String? {
        let identifier = (device as NSString).lastPathComponent
        // Already mounted is a success, not an error: a physical drive is
        // usually mounted by macOS before this app has even seen it.
        _ = diskutil(["mountDisk", device])
        return mountPoint(ofDisk: identifier)
    }

    /// Where macOS has mounted anything belonging to this disk.
    public static func mountPoint(ofDisk identifier: String) -> String? {
        mountPoint(ofDisk: identifier, in: mountTable())
    }

    /// "/dev/disk5s1 on /Volumes/EXFATTEST (exfat, local, ...)"
    public static func mountPoint(ofDisk identifier: String, in table: String) -> String? {
        for line in table.components(separatedBy: .newlines) {
            guard line.hasPrefix("/dev/") else { continue }
            let device = String(line.prefix(while: { !$0.isWhitespace }).dropFirst(5))
            // The disk itself or one of its partitions, and not disk50 when
            // asked about disk5.
            guard device == identifier || device.hasPrefix(identifier + "s") else { continue }
            guard let on = line.range(of: " on "),
                let paren = line.range(of: " (", range: on.upperBound..<line.endIndex)
            else { continue }
            return String(line[on.upperBound..<paren.lowerBound])
        }
        return nil
    }

    private static func mountTable() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    private static func diskutil(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

extension DiskImage {
    /// Whether this file is a qcow2, by its magic rather than its name.
    ///
    /// An extension proves nothing, and a qcow2 is often named `.img`. The
    /// engine reads the format itself, so such a file is never attached; it is
    /// handed to the engine as a path. That is why it must be told apart from a
    /// raw image before anything else happens.
    public static func isQcow2(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB])  // QFI\xfb
    }

    /// What the engine says is inside an image it can read itself.
    ///
    /// Its own probe, run unprivileged, for the formats no sector read here can
    /// answer for: everything in a qcow2 is behind the container's mapping.
    ///
    ///     0:   crypto_LUKS            +335.5 MB   container.qcow2
    ///     0:   btrfs LUKOTTAPLAIN     +335.5 MB   plain.qcow2
    public static func contents(of url: URL) -> [String] {
        guard let engine = EnginePaths.anylinuxfs else { return [] }
        let p = Process()
        p.executableURL = engine
        p.arguments = ["list", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return types(inListing: String(data: data, encoding: .utf8) ?? "")
    }

    /// The TYPE column of the engine's listing, in order.
    public static func types(inListing text: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // "0:   crypto_LUKS   +335.5 MB   name": the row number, then the
            // type. The header line has no colon-terminated number.
            guard fields.count >= 2, fields[0].hasSuffix(":"),
                Int(fields[0].dropLast()) != nil
            else { continue }
            found.append(String(fields[1]))
        }
        return found
    }

    /// What that listing means for whether a passphrase is needed.
    public static func format(fromTypes types: [String]) -> VolumeFormat {
        // Any encrypted volume in the image means a passphrase is wanted; the
        // engine opens the container before it can see anything inside.
        if types.contains(where: { $0.hasPrefix("crypto_") }) { return .luks }
        if types.contains("BitLocker") || types.contains("bitlocker") { return .bitlocker }
        for type in types {
            switch type {
            case "ntfs", "ntfs3": return .ntfs
            case "exfat": return .exfat
            case "btrfs": return .btrfs
            case "xfs": return .xfs
            case "ext2", "ext3", "ext4": return .ext
            default: continue
            }
        }
        return .unknown
    }
}
