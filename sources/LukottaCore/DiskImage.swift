// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import CryptoKit
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
/// Which container an image file is, once it has been recognised.
///
/// The formats differ in what can be done with them, not only in how they are
/// read: a VHDX is read and never written, and the ones written here are
/// written by drivers built for this application rather than by anything with
/// a long history behind it. The screen that offers to open an image says so,
/// which is why this is carried as far as the interface rather than being left
/// to the engine.
public enum ContainerFormat: String, Sendable {
    /// Attached by macOS: an ordinary disk in a file.
    case raw
    case qcow2
    case vmdk
    /// The form an OVA carries: every grain deflated, written in one pass, and
    /// so readable and not changeable.
    case vmdkStreamed
    case vdi
    case vhd
    case vhdx

    /// What to call it on screen.
    public var name: String {
        switch self {
        case .raw: return appString("raw image")
        case .qcow2: return appString("qcow2")
        case .vmdk, .vmdkStreamed: return appString("VMDK")
        case .vdi: return appString("VDI")
        case .vhd: return appString("VHD")
        case .vhdx: return appString("VHDX")
        }
    }

    /// Whether anything can be written to an image in this format.
    ///
    /// A VHDX cannot: changing one means writing to its log first, which the
    /// driver does not do. Nor can a stream-optimized VMDK: every grain in one
    /// is deflated and written in a single pass, so changing one in place would
    /// rarely produce the same number of bytes.
    public var isWritable: Bool { self != .vhdx && self != .vmdkStreamed }

    /// Whether writing goes through a driver written for this application.
    ///
    /// True only of the formats whose drivers were written here. False for a
    /// raw image, which macOS attaches and writes as it writes any disk, and
    /// false for qcow2, which imago has written for years: somebody else's
    /// tested code is not this application's warning to give.
    ///
    /// VMDK counts, the sparse form being read and written by the driver added
    /// here, and nothing at this level tells a sparse one from a flat one.
    public var writtenByOurOwnDriver: Bool {
        switch self {
        case .raw, .qcow2, .vhdx, .vmdkStreamed: return false
        case .vmdk, .vdi, .vhd: return true
        }
    }
}

/// How large a file is, or zero where it cannot be told.
///
/// `try?` over an `as?` yields an optional optional, so written out at a call
/// site this reads as one `?? 0` too many and invites a second that does
/// nothing. Asked here, it is one question with one answer.
public func fileSize(atPath path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.size] as? Int64 ?? 0
}

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
        // Already attached is already attached. A file this app put back a
        // moment ago can still be held by the machine that was serving it, and
        // attaching it a second time either fails or produces a second device
        // for one file. Opening something twice should be opening it, so the
        // attachment that exists is the answer.
        //
        // Only on an answer: hdiutil timing out would otherwise read as "not
        // attached" and produce a second device for one file, which is two
        // views of the same bytes and the shortest route to a corrupt volume.
        if let listing = attachments() {
            if let device = listing.first(where: { $0.value == url.path })?.key {
                return .success(Attached(device: "/dev/" + device, url: url))
            }
        } else {
            Log.drives.error("hdiutil did not say what is attached; not opening a second copy")
            return .failure(
                .nothingToOpen(
                    appString("This file could not be opened just now. Try again in a moment.")))
        }

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
        wholeDiskContents(attached, url: url)?.drive
    }

    /// The same, with what the first sector turned out to be. The row can then
    /// say what is in the file rather than what its partition type suggests,
    /// there being no partition type at all.
    public static func wholeDiskContents(_ attached: Attached, url: URL)
        -> (drive: Drive, format: VolumeFormat)?
    {
        guard let sector = BootSector.read(devicePath: attached.device) else { return nil }
        let format = BootSector.identify(sector)
        let kind: VolumeKind
        switch BootSector.identify(sector) {
        case .luks, .ext, .btrfs, .xfs: kind = .linux
        case .bitlocker, .ntfs, .exfat: kind = .microsoft
        case .unknown: return nil
        }
        let size = fileSize(atPath: url.path)
        let drive = Drive(
            id: attached.identifier,
            devicePath: attached.device,
            // The file's name without its extension, which is what the drive is
            // called in Finder afterwards.
            name: url.deletingPathExtension().lastPathComponent,
            sizeBytes: size,
            connection: appString("Disk Image"),
            kind: kind,
            // The file it came from, so that a passphrase remembered for this
            // container is found again next time. The device it attaches as
            // changes on every attach.
            uuid: url.path)
        return (drive, format)
    }

    /// Devices still attached from a file this app opened, with nothing mounted
    /// from them.
    ///
    /// A crash, a forced quit, or a device that would not let go leaves one
    /// behind. It has no volume mounted -- nothing appears in Finder -- so the
    /// only sign of it is a disk in the list that nobody recognises.
    ///
    /// Only files this app opened, which is what `ours` carries. Judged by
    /// hdiutil for what came from which file and by the mount table for what is
    /// in use; one that is in use belongs to whoever is using it.
    ///
    /// The list matters. Read as "every attached image nothing is mounted
    /// from", this put back images belonging to other programs: somebody who
    /// attaches a raw image in Terminal and then opens this app finds their
    /// image detached, by an app that never touched it.
    public static func strayAttachments(ours: Set<String>) -> [String] {
        strayAttachmentsWithFiles(ours: ours).map(\.device)
    }

    /// The same, with the file each device is serving.
    ///
    /// The pair matters because a device identifier is reused the moment it is
    /// free: disk5 detached is disk5 again at the next attach. A list of
    /// identifiers gathered a second ago and acted on now can name a device
    /// that has since become something else -- and detaching it takes down a
    /// drive somebody is in the middle of opening, which then reads as a
    /// filesystem nothing recognises.
    public static func strayAttachmentsWithFiles(ours: Set<String>) -> [(
        device: String, file: String
    )] {
        guard !ours.isEmpty, let attached = attachments() else { return [] }
        let busy = MountTableEntry.all(in: mountTable()).map(\.source)
        return attached.compactMap { identifier, path in
            guard ours.contains(path) else { return nil }
            let device = "/dev/" + identifier
            guard !busy.contains(where: { $0.hasPrefix(device) }) else { return nil }
            return (device, path)
        }
    }

    /// Detach a device only while it is still serving the file it was found
    /// with. An identifier that has been recycled since belongs to something
    /// else now and is left alone.
    @discardableResult
    public static func detachIfStillBacking(device: String, file: String) -> Bool {
        let identifier = (device as NSString).lastPathComponent
        // No answer is not a match: a device is detached only on evidence that
        // it is still the one that was found.
        guard let listing = attachments(), listing[identifier] == file else { return false }
        detach(device)
        return true
    }

    /// The files this app has attached, kept where it can be read after a crash.
    ///
    /// Nothing else can say afterwards which attachment was this app's doing:
    /// hdiutil reports what is attached, not who asked for it.
    public enum OpenedFiles {
        static let key = "attachedByLukotta"

        public static func all() -> Set<String> {
            Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }

        public static func add(_ path: String) {
            UserDefaults.standard.set(Array(all().union([path])).sorted(), forKey: key)
        }

        public static func remove(_ path: String) {
            UserDefaults.standard.set(Array(all().subtracting([path])).sorted(), forKey: key)
        }
    }

    @discardableResult
    public static func detach(_ device: String) -> Bool {
        // Forced: the eject that precedes this has already taken the filesystem
        // down, and a lingering reference would keep the image file locked.
        if run(["detach", device, "-force"]).status == 0 { return true }

        // Something still holds it. Nearly always a volume served from it that
        // has not finished going away, and hdiutil answers before the system
        // has let go, so the first refusal means "not yet" more often than it
        // means "no". Take the volumes down and ask again.
        //
        // Asked once and never checked, a refusal left the image attached with
        // nothing to say so: the file turned up in the next session's list as a
        // disk nobody recognised, which is how two of them accumulated.
        LukottaCore.run("/usr/sbin/diskutil", ["unmountDisk", "force", device], timeout: 20)
        for attempt in 1...3 {
            Thread.sleep(forTimeInterval: 0.4 * Double(attempt))
            if run(["detach", device, "-force"]).status == 0 { return true }
        }
        Log.drives.error(
            "could not put back \(device, privacy: .public); it is still attached")
        return false
    }

    /// hdiutil, with a deadline: attaching an image that is on a network
    /// share, or a device that has gone away, can otherwise wait for ever.
    static func run(_ arguments: [String], timeout: TimeInterval = 30) -> (
        status: Int32, out: String
    ) {
        guard let result = LukottaCore.run("/usr/bin/hdiutil", arguments, timeout: timeout) else {
            return (1, "")
        }
        return (result.status, result.out)
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
        // A container with no partition table is offered by the scan as the
        // disk itself, named after the device it was attached on. The row made
        // from the file is that same volume said in terms that outlive the
        // attachment -- the file's name, and the file as what a passphrase is
        // remembered against -- so it takes the scan's place rather than being
        // dropped beside it as a duplicate.
        var listed: [Drive] = []
        for drive in found {
            let whole = DriveScanner.wholeDisk(of: drive.id)
            if drive.id == whole, let image = images[whole] {
                listed.append(image)
            } else {
                listed.append(drive)
            }
        }
        let present = Set(found.map { DriveScanner.wholeDisk(of: $0.id) })
        return listed + images.filter { !present.contains($0.key) }.values
    }

    /// Which containers to detach when the app is quitting.
    ///
    /// Everything it attached, except what is still serving a mount somebody
    /// chose to leave open: that mount reads through the device, and taking the
    /// device away would break a drive the person just asked to keep.
    ///
    /// Attaching is this application's business and not the reader's. Nothing
    /// in the interface mentions it, and a container left attached after a quit
    /// turns up in the list next time as a disk nobody recognises.
    public static func detachingOnQuit(opened: [String: URL], mountedDevices: [String]) -> [String]
    {
        let busy = Set(
            mountedDevices.map { DriveScanner.wholeDisk(of: ($0 as NSString).lastPathComponent) })
        return opened.keys.filter { !busy.contains($0) }.sorted()
    }

    /// Which containers should be detached, given the devices just ejected.
    ///
    /// Driven by what was ejected rather than by what is absent from the list. A
    /// container that has been opened and not yet mounted is absent from
    /// nothing, and detaching it because another drive was ejected would remove
    /// it from whoever just opened it.
    /// Every container this app attached is a candidate, not only the ones it
    /// had to make a row for by hand. A container with a partition table is
    /// listed by the scan like any disk, so it was absent from that shorter
    /// set, and ejecting one left the file attached with nothing to say so.
    public static func detaching(devices: [String], images: Set<String>) -> [String] {
        let ejected = Set(
            devices.map { DriveScanner.wholeDisk(of: ($0 as NSString).lastPathComponent) })
        return images.filter { ejected.contains($0) }.sorted()
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
    /// Which file each attached disk was made from, by whole-disk identifier.
    ///
    /// A device identifier is handed straight back out once it is free: detach
    /// the image at disk6, attach another, and the second one is disk6 too.
    /// Anything remembered about an image under its device name is therefore
    /// about whichever image holds that name now. That is how a passphrase
    /// saved for one image came to be offered for another, and how ejecting a
    /// drive detached an image that had nothing to do with it.
    ///
    /// So the mapping is not remembered. It is asked for, and this is the only
    /// thing that answers it.
    ///
    /// Nil where `hdiutil` could not be asked at all, which is not the same
    /// answer as "nothing is attached": treating it as the second detaches
    /// every image somebody has open.
    public static func attachments() -> [String: String]? {
        let listing = run(["info"], timeout: 15)
        guard listing.status == 0 else { return nil }
        var map: [String: String] = [:]
        var path = ""
        for line in listing.out.components(separatedBy: .newlines) {
            if line.hasPrefix("image-path") {
                path = line.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("/dev/disk"), !path.isEmpty {
                let device = line.components(separatedBy: .whitespaces)[0]
                map[DriveScanner.wholeDisk(of: (device as NSString).lastPathComponent)] = path
            }
        }
        return map
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
        if let point = mountPoint(ofDisk: identifier) { return point }

        // Asked for, then waited for. macOS mounts through diskarbitration,
        // which answers this command before the volume is in the mount table --
        // and an image attached a moment ago is often still being probed, so
        // the first attempt returns "busy" and a second, a second later, works.
        //
        // Read once, this looked exactly like a disk macOS would not mount, and
        // the person was told their image might already be open in Finder while
        // it was quietly mounting behind the message.
        for attempt in 0..<15 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            _ = diskutil(["mountDisk", device])
            if let point = mountPoint(ofDisk: identifier) { return point }
        }
        Log.drives.notice("macOS did not mount \(identifier, privacy: .public) within six seconds")
        return nil
    }

    /// Where macOS has mounted anything belonging to this disk.
    public static func mountPoint(ofDisk identifier: String) -> String? {
        mountPoint(ofDisk: identifier, in: mountTable())
    }

    /// "/dev/disk5s1 on /Volumes/EXFATTEST (exfat, local, ...)"
    public static func mountPoint(ofDisk identifier: String, in table: String) -> String? {
        MountTableEntry.all(in: table).first { entry in
            guard entry.source.hasPrefix("/dev/") else { return false }
            let device = String(entry.source.dropFirst(5))
            // The disk itself or one of its partitions, and not disk50 when
            // asked about disk5.
            return device == identifier || device.hasPrefix(identifier + "s")
        }?.mountPoint
    }

    @discardableResult
    private static func diskutil(_ arguments: [String]) -> Int32 {
        LukottaCore.run("/usr/sbin/diskutil", arguments)?.status ?? 1
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
        // A file the engine cannot open yet is not a file with nothing in it.
        //
        // The machine that was serving this image a moment ago holds it while
        // it shuts down, and asking during that second comes back empty --
        // which the screen then reports as "there is nothing in it that can be
        // opened", about a file the person has just been reading. Ejecting a
        // drive and opening it again is the most ordinary thing there is, so
        // the question is asked again rather than answered wrongly.
        // Bounded by the clock as well as by the count. Each of these asks the
        // engine, which starts a machine to answer; five of them against an
        // image that will never be readable is most of a minute of somebody
        // watching a spinner to be told what the first attempt already knew.
        let givingUpAt = Date().addingTimeInterval(20)
        for attempt in 1...5 {
            guard
                let result = LukottaCore.run(
                    engine.path, ["list", withoutSpaces(url).path],
                    environment: EngineEnvironment.environmentForEngine())
            else { return [] }
            let found = types(inListing: result.out)
            if !found.isEmpty { return found }
            // An empty answer means one of two things, and they are not the
            // same: the engine looked and there is nothing in this file, or the
            // engine never got as far as looking. It says which -- a machine
            // that would not start, an image it could not hold, a probe that
            // ended -- through its status and whatever it wrote to stderr.
            //
            // Only the first is an answer. The second was being reported to the
            // person as "there is nothing in it that can be opened", about an
            // image that opens perfectly well a second later, which is how a
            // run of these under load produced a file that had worked all
            // afternoon suddenly holding nothing.
            let complaint = (result.out + result.err).lowercased()
            let wentWrong = result.status != 0 || !result.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let busy =
                complaint.contains("locked") || complaint.contains("busy")
                || complaint.contains("in use") || complaint.contains("resource temporarily")
            guard busy || wentWrong, attempt < 5, Date() < givingUpAt else { return found }
            Log.drives.notice(
                "the engine did not answer for this image (attempt \(attempt, privacy: .public)); asking again"
            )
            Thread.sleep(forTimeInterval: 0.6)
        }
        return []
    }

    /// A path to this image with no space in it.
    ///
    /// The engine takes a path as far as its first space and no further: asked
    /// about "Open Drive.vdi" it looks for "/Users/someone/Desktop/Open" and
    /// reports that there is no such disk. The app then has nothing to show for
    /// the file and says so -- an image that opens perfectly well under any
    /// other name. Only the space does this; quotes, ampersands, hashes,
    /// accented letters and CJK all pass through.
    ///
    /// A link stands in. It is named from a digest of the path, so two images
    /// called the same thing in different folders do not collide, and it is
    /// replaced each time, so it cannot point at a file that has since moved.
    /// A file whose path has no space is handed over as it is.
    public static func withoutSpaces(_ url: URL) -> URL {
        guard url.path.contains(" ") else { return url }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard
            let directory = caches?
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lukotta")
                .appendingPathComponent("images", isDirectory: true)
        else { return url }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var name = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }
            .joined()
        if !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        let link = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        } catch {
            return url
        }
        return link
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
