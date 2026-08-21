import Foundation

/// Opening an encrypted container that is a file rather than a drive.
///
/// A LUKS container made with `cryptsetup luksFormat container.img` is the
/// common case, and Windows' equivalent is a VHDX with BitLocker switched on
/// inside it. Both are ordinary files holding what a drive would hold.
///
/// macOS attaches the file and hands back a `/dev/diskN`, and from there
/// everything else in the app works unmodified: the scan, the first-sector
/// probe, the claim, the mount, the eject. That is why it is done this way
/// rather than by handing the path to the engine, which also accepts one — the
/// attach happens as the user, so the root helper still only ever sees a device
/// node, and a file name chosen by whoever is at the keyboard never reaches it.
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
    /// Nothing is mounted by macOS, deliberately: an NTFS volume it recognises
    /// would otherwise be mounted read-only behind our back, and the engine
    /// then cannot have the device.
    /// How long macOS is given to attach a file.
    ///
    /// Attaching is normally instant. A file on a slow or unreachable disk —
    /// a network share that has gone away — is where it is not, and there the
    /// alternative is a spinner that never stops.
    public static let attachTimeout: TimeInterval = 30

    public static func attach(_ url: URL, timeout: TimeInterval = attachTimeout) -> Result<
        Attached, Failure
    > {
        // Plain first. A raw image — which is what `dd` and cryptsetup produce,
        // and the common shape for a LUKS container — has no header for macOS
        // to recognise, and is only attachable when told what it is.
        //
        // Which means almost anything attaches: a raw image is only bytes, so
        // a text file becomes a very small disk holding nothing. Attaching is
        // therefore not the question. What is inside is, and that is answered
        // after this by looking — a file holding nothing recognisable is
        // detached again and reported as unopenable.
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
    /// Returns nil for anything not recognised, which is what keeps an
    /// unopenable file out of the list rather than in it saying "unknown".
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
            // The file's name, without the extension nobody thinks of as part
            // of it. This is what the drive is called in Finder afterwards.
            name: url.deletingPathExtension().lastPathComponent,
            sizeBytes: size ?? 0,
            connection: appString("Disk Image"),
            kind: kind,
            // The file it came from, so a passphrase remembered for this
            // container is found again next time it is opened — the device it
            // attaches as changes every time.
            uuid: url.path)
    }

    @discardableResult
    public static func detach(_ device: String) -> Bool {
        // Forced, because the eject that precedes this has already taken the
        // filesystem down and a lingering reference should not keep the image
        // file locked afterwards.
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

        // The deadline is watched before the pipe is read: reading to the end
        // would itself wait for a process that is not going to finish.
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
/// The decisions only, with no state and no interface, so the two rules that
/// went wrong can be stated and checked: a container the scan cannot see is put
/// back, and a container is taken out when it is the thing being ejected.
public enum ImageList {

    /// A scan's results with the container rows the scan cannot produce.
    ///
    /// A container with no partition table is reported by `diskutil` as an
    /// empty disk, so no scan will ever return it. The row is made once, from
    /// the first sector, and has to be added back whenever the list is rebuilt.
    public static func merge(found: [Drive], images: [String: Drive]) -> [Drive] {
        guard !images.isEmpty else { return found }
        let present = Set(found.map { DriveScanner.wholeDisk(of: $0.id) })
        return found + images.filter { !present.contains($0.key) }.values
    }

    /// Which containers should be detached, given the devices just ejected.
    ///
    /// Driven by what was ejected rather than by what is missing from the list.
    /// A container that has been opened and not yet mounted is missing nothing,
    /// and detaching it because some other drive was ejected would take it away
    /// from the person who just opened it.
    public static func detaching(devices: [String], images: [String: Drive]) -> [String] {
        let ejected = Set(
            devices.map { DriveScanner.wholeDisk(of: ($0 as NSString).lastPathComponent) })
        return images.keys.filter { ejected.contains($0) }.sorted()
    }
}

extension DiskImage {
    /// Which of these disks are still attached.
    ///
    /// A container file can go away without anything asking us: detached in
    /// Finder, or on a drive that was unplugged. The device node is the answer,
    /// and asking is a stat.
    public static func stillAttached(_ identifiers: Set<String>) -> Set<String> {
        identifiers.filter { FileManager.default.fileExists(atPath: "/dev/" + $0) }
    }
}

extension DiskImage {
    /// Which devices these image files are attached as, if any.
    ///
    /// For clearing up after a run that ended early: an image left attached
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
                // The whole disk, not its partitions: detaching that takes the
                // rest with it.
                if !device.dropFirst(9).contains("s") { devices.append(device) }
            }
        }
        return devices
    }
}
