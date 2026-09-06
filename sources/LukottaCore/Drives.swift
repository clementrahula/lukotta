// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

// MARK: - Drives

/// What we can tell about a partition before anything is unlocked.
public enum VolumeKind: String, Hashable, Sendable {
    /// GPT "Microsoft Basic Data" — BitLocker or plain NTFS, indistinguishable
    /// until an unlock is attempted.
    case microsoft
    /// A Linux partition — LUKS, or an unencrypted Linux filesystem.
    case linux

    /// The kind to mount by, once the first sector has been read.
    ///
    /// A disk with no partition table has no partition type to read, so the
    /// scan calls it Linux -- a whole disk handed to cryptsetup is what makes
    /// one. That guess picks the mount ladder and, with it, whether a dirty
    /// NTFS is repaired, so a stick formatted NTFS with no partition table,
    /// and every raw image of one, was opened as a Linux volume and never
    /// repaired.
    ///
    /// Both directions, since 2026-09-06. A partition type was treated as a
    /// fact about the disk when it says Microsoft, and it is not one: it is a
    /// claim written when the disk was partitioned, and it stays behind when
    /// somebody reformats the volume inside it.
    ///
    /// Measured that morning on a stick whose exFAT was replaced with a LUKS
    /// container: the MBR still typed it Windows_NTFS, the daemon's own reading
    /// of the first sector said LUKS, and the type won -- so an encrypted Linux
    /// volume was handed to the ntfs3 driver with `iocharset=utf8` and the open
    /// ended in "wrong fs type, bad option, bad superblock".
    ///
    /// The sector is what the volume is. The type is only consulted where the
    /// sector says nothing this app recognises.
    public static func settled(_ declared: VolumeKind, sectorSays format: VolumeFormat)
        -> VolumeKind
    {
        guard let probed = format.kind else { return declared }
        return probed
    }

    /// Whether a partition of this type is one this app exists to open, and
    /// what it may hold.
    ///
    /// The name is what `diskutil` prints for the partition's type, and it
    /// depends on the scheme the disk was partitioned with. A GPT disk gives
    /// the readable name of the type GUID; an MBR disk -- which is what
    /// Windows still writes on a USB stick, and what BitLocker To Go leaves
    /// behind -- gives the old DOS name instead. Reading only the GPT names
    /// meant a BitLocker drive from a Windows machine was filtered out before
    /// anything looked at it, and the app reported no encrypted drives on a
    /// Mac with one plugged in.
    ///
    /// Nothing finer can be told apart here. Microsoft Basic Data and
    /// Windows_NTFS each cover BitLocker, NTFS and exFAT alike, and only the
    /// boot sector says which.
    public static func holding(_ content: String) -> VolumeKind? {
        switch content {
        case "Microsoft Basic Data", "Windows_NTFS":
            return .microsoft
        case "Linux Filesystem", "Linux_Filesystem", "Linux",
            "Linux LVM", "Linux_LVM", "Linux RAID", "Linux_RAID":
            return .linux
        default:
            return nil
        }
    }

    /// What the volume may be, named as precisely as is known.
    ///
    /// Before anything is read, a partition type is all there is, and it admits
    /// two answers: a Microsoft Basic Data partition is BitLocker or NTFS, and
    /// a Linux one is LUKS or a filesystem not yet identified. Once a probe has
    /// said which, that one name is the answer and the pair is no longer true.
    ///
    /// Written rather than translated: every name in it is a product or a
    /// filesystem, and those are the same in every language.
    public func summary(knowing format: VolumeFormat? = nil, holding filesystem: String? = nil)
        -> String
    {
        if let format, format != .unknown {
            // An encrypted drive is two things, and once it is open both are
            // known: the lock and what is behind it.
            guard format.isEncrypted, let filesystem, !filesystem.isEmpty else {
                return format.name
            }
            return format.name + "/" + filesystem
        }
        switch self {
        case .microsoft: return "BitLocker/NTFS"
        // The pair, as above: the lock or the filesystem, since a Linux
        // partition type says only that it is one of the two. Saying "LUKS"
        // alone put that word over every unencrypted ext4 stick in the list.
        case .linux: return "LUKS/Linux"
        }
    }

    public var summary: String { summary() }
}

/// The order rows are shown in: the order they arrived.
///
/// A list rebuilt from a scan and a couple of dictionaries comes back in
/// whatever order those produced, and a dictionary has none at all. So opening
/// a second image moved the first, a drive plugged in third landed in the
/// middle, and rows changed places on a refresh with nothing having happened.
///
/// A row keeps its place for as long as it is there, and anything new goes to
/// the bottom -- a drive and a container file alike, there being one list and
/// not two. What identifies a row is given by the caller, because a device
/// name is not it: those are handed back out as soon as they are free.
public struct DriveOrder: Sendable {
    /// The order the rows are in now.
    private var seen: [String]

    /// The places somebody gave the rows themselves.
    ///
    /// These are kept whether the row is there or not, and they are the part
    /// that outlives the session. An order nobody arranged is the order things
    /// turned up in, and a drive plugged in again is a drive turning up: it
    /// goes to the bottom with the rest of the new arrivals rather than
    /// reappearing in the middle of a list from a fortnight ago.
    private var arranged: [String]

    /// How many places to remember. Enough for every drive and file somebody
    /// arranges, and not enough to grow without end.
    private static let limit = 200

    public init(arrangement: [String] = []) {
        arranged = arrangement
        seen = arrangement
    }

    /// The arrangement, to be kept somewhere that outlives the app. An order
    /// somebody made by hand and lost at the next launch would be worse than
    /// not being able to make one.
    public var arrangement: [String] { arranged }

    /// The same drives, in the order they were first seen -- or in the order
    /// somebody put them in, where they did.
    public mutating func apply(_ drives: [Drive], key: (Drive) -> String) -> [Drive] {
        var byKey: [String: Drive] = [:]
        for drive in drives {
            let identity = key(drive)
            if byKey[identity] == nil { byKey[identity] = drive }
        }
        let kept = Set(arranged)
        seen = seen.filter { byKey[$0] != nil || kept.contains($0) }
        for drive in drives where !seen.contains(key(drive)) { seen.append(key(drive)) }
        return seen.compactMap { byKey[$0] }
    }

    /// Take an order somebody arranged themselves.
    ///
    /// Every row they could see is part of it, whether they dragged that one or
    /// not: what they arranged is the order they left the list in.
    public mutating func adopt(_ keys: [String]) {
        let moved = Set(keys)
        seen = keys + seen.filter { !moved.contains($0) }
        arranged = seen
        if arranged.count > Self.limit { arranged.removeLast(arranged.count - Self.limit) }
    }
}

/// Where an arrangement of the list is kept between launches.
///
/// Beside the rest of the app's settings. What it holds is what each row is --
/// a volume's own UUID, or the path of a file somebody opened -- so it says
/// nothing about a drive that is not plugged in and nothing about the machine.
public enum ListOrderMemory {
    static let key = "listOrder"

    public static func read() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    public static func write(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: key)
    }
}

public struct Drive: Identifiable, Hashable, Sendable {
    public let id: String  // disk4s1
    public let devicePath: String  // /dev/disk4s1
    public let name: String  // best human-readable label we can find
    public let sizeBytes: Int64
    public let connection: String  // e.g. "USB · External"
    public let kind: VolumeKind
    /// Partition UUID, stable across replugging, unlike diskNsM.
    public let uuid: String
    /// Whether the partition type says anything about what is inside.
    ///
    /// It does for a partition: Microsoft Basic Data is BitLocker or NTFS, a
    /// Linux partition is LUKS or a Linux filesystem, and the row can say so.
    /// A disk with no partition table has no type at all -- it is a stick
    /// somebody ran cryptsetup or mkfs over, and it could equally be BitLocker
    /// written without a table. Guessing there produced a row that said LUKS
    /// over a plain ext4 stick, so such a row says nothing until something has
    /// read the first sector.
    public let kindIsKnown: Bool

    /// The same volume, once its first sector has been read.
    ///
    /// The kind follows the sector where the two disagree, by the rule in
    /// `VolumeKind.settled`, and a volume whose sector named a format is no
    /// longer one this app is guessing about.
    public func knowing(_ format: VolumeFormat) -> Drive {
        Drive(
            id: id, devicePath: devicePath, name: name, sizeBytes: sizeBytes,
            connection: connection, kind: VolumeKind.settled(kind, sectorSays: format),
            uuid: uuid, kindIsKnown: format.kind != nil || kindIsKnown)
    }

    public init(
        id: String, devicePath: String, name: String, sizeBytes: Int64,
        connection: String, kind: VolumeKind, uuid: String, kindIsKnown: Bool = true
    ) {
        self.id = id
        self.devicePath = devicePath
        self.name = name
        self.sizeBytes = sizeBytes
        self.connection = connection
        self.kind = kind
        self.uuid = uuid
        self.kindIsKnown = kindIsKnown
    }

    public var sizeDescription: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }

    /// Whether a mount's key or device path belongs to this drive.
    ///
    /// A mount is reported either by device path or, for a volume inside a
    /// container, as "lvm:<vg>:<disk>:<lv>" — so the disk identifier is looked
    /// for inside the string. Plainly asking whether it is contained is not
    /// enough: "disk4s1" is contained in "disk4s10", and a disk with ten or
    /// more partitions then reports one partition's state against another, or
    /// closes the wrong one.
    ///
    /// A digit may not follow, which separates disk4s1 from disk4s10, and a
    /// letter or digit may not precede. A letter may still follow, so that a
    /// whole disk still recognises the mounts of its partitions.
    public func owns(_ identifier: String) -> Bool {
        guard !id.isEmpty else { return false }
        var searched = Substring(identifier)
        while let found = searched.range(of: id) {
            let beforeOK =
                found.lowerBound == identifier.startIndex
                || !identifier[identifier.index(before: found.lowerBound)].isLetter
                    && !identifier[identifier.index(before: found.lowerBound)].isNumber
            let afterOK =
                found.upperBound == identifier.endIndex
                || !identifier[found.upperBound].isNumber
            if beforeOK && afterOK { return true }
            searched = identifier[found.lowerBound...].dropFirst()
        }
        return false
    }

    public var subtitle: String {
        connection.isEmpty
            ? "\(sizeDescription) · \(kind.summary) · \(id)"
            : "\(sizeDescription) · \(connection) · \(kind.summary) · \(id)"
    }
}

/// Finds partitions that could be BitLocker volumes.
///
/// Without root we cannot read the FVE header, so classification is by GPT
/// partition type: BitLocker volumes are "Microsoft Basic Data", the same type
/// plain NTFS uses. The UI is honest about that rather than claiming certainty.
/// One answer per volume for the length of a scan.
///
/// `diskutil info` is a process, and the scan asks about every volume twice --
/// once for the list and once for the leftovers the partition types dropped.
private final class InfoCache {
    private var held: [String: [String: Any]] = [:]
    func value(for key: String, _ make: () -> [String: Any]) -> [String: Any] {
        if let hit = held[key] { return hit }
        let made = make()
        held[key] = made
        return made
    }
}

public enum DriveScanner {
    /// Every drive worth showing, plus the container files we were asked to
    /// open.
    ///
    /// Disk images are otherwise left out: whatever else is attached — an
    /// installer, a backup, something the user mounted themselves — is not
    /// this app's business, and listing it would be a surprise. The ones opened
    /// through File are named here so they, and only they, come back.
    ///
    /// LUKOTTA_INCLUDE_IMAGES=1 lets them all in, which is how the interface is
    /// exercised with several drives without owning several drives.
    public static func scan(images: Set<String> = []) -> [Drive] {
        survey(images: images).listed
    }

    /// The list, and the volumes the partition types alone would throw away.
    ///
    /// A partition type is a claim about a volume, and on a USB stick it is
    /// often a stale one. An NTFS stick that had once been formatted on a Mac
    /// came back as an Apple partition map holding Apple_HFS, and its one
    /// volume -- exFAT, by its own first sector -- was dropped before anything
    /// looked at it: the app reported no drive at all for a stick plugged into
    /// the machine. Nothing here can read that sector, since a device node
    /// belongs to root, so the leftovers are handed back rather than discarded
    /// and whoever can read them decides.
    ///
    /// Both halves come out of one reading of the table. A second `diskutil
    /// list` would be a second answer, and two answers about the same machine
    /// taken a moment apart is how a drive ends up in neither.
    public static func survey(images: Set<String> = []) -> (listed: [Drive], unclaimed: [Drive]) {
        let all = ProcessInfo.processInfo.environment["LUKOTTA_INCLUDE_IMAGES"] == "1"
        var argv = ["/usr/sbin/diskutil", "list", "-plist"]
        if !all && images.isEmpty { argv.append("physical") }
        guard let plist = runPlist(argv) else { return ([], []) }
        // One `diskutil info` per volume, not one per pass.
        //
        // The two passes ask about overlapping sets, and each question is a
        // process. On a Mac with several images attached that doubled the
        // slowest part of a scan: the opening scan stopped finishing inside the
        // thirty seconds the end-to-end harness allows, and the list churned
        // while it caught up.
        let answers = InfoCache()
        let ask: (String) -> [String: Any] = { identifier in
            answers.value(for: identifier) { info(for: identifier) ?? [:] }
        }
        let found = drives(inList: plist, info: ask)
        let leftovers = unclaimedVolumes(inList: plist, info: ask)
        guard !all, !images.isEmpty else { return (found, leftovers) }
        // Everything came back, so the images nobody asked about go now. A
        // partition of disk6 belongs to disk6.
        let physical = Set(
            (runPlist(["/usr/sbin/diskutil", "list", "-plist", "physical"])?["WholeDisks"]
                as? [String]) ?? [])
        let mine: ([Drive]) -> [Drive] = { rows in
            rows.filter { drive in
                let whole = wholeDisk(of: drive.id)
                return physical.contains(whole) || images.contains(whole)
            }
        }
        return (mine(found), mine(leftovers))
    }

    /// A name for a volume whose partition table carries no UUID.
    ///
    /// The medium's own name, the volume's size and where it begins on the
    /// disk: none of the three changes when the drive is unplugged and put back
    /// into another port, which is what the device identifier does. Two
    /// identical drives of the same make and size, partitioned identically,
    /// would share a name -- and would also be indistinguishable to anything
    /// else that looked.
    ///
    /// Nil when there is not enough to go on, so the caller falls back to the
    /// device identifier rather than to a name several drives would share.
    public static func stableName(media: String?, size: Int64, offset: Int64?)
        -> String?
    {
        guard let media, !media.isEmpty, size > 0 else { return nil }
        let cleaned = media.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return "media:\(cleaned):\(size):\(offset ?? 0)"
    }

    /// "disk6s1" belongs to "disk6".
    ///
    /// By taking the digits after "disk" rather than cutting at an "s": the
    /// word "disk" contains one, and a synthesised volume is named disk3s1s1,
    /// so cutting at the first or the last would both be wrong.
    public static func wholeDisk(of identifier: String) -> String {
        guard identifier.hasPrefix("disk") else { return identifier }
        let digits = identifier.dropFirst(4).prefix { $0.isNumber }
        return digits.isEmpty ? identifier : "disk" + digits
    }

    /// The parsing, with the two `diskutil` calls handed in.
    ///
    /// Separated from `scan` so it can be given captured output instead of a
    /// machine with the right drives plugged into it. Everything that decides
    /// what appears in the list, and what it is called, is in here.
    public static func drives(
        inList plist: [String: Any],
        info: (String) -> [String: Any]
    ) -> [Drive] {
        rows(inList: plist, info: info, claimed: true)
    }

    /// The volumes the partition types dropped: external, not a whole disk, and
    /// of a type this app makes nothing of.
    ///
    /// Provisional, every one of them -- an EFI partition and an APFS container
    /// come out of here too. They are worth a row only if their first sector
    /// names a format the app opens, and that reading needs root, so these are
    /// candidates handed to whoever can read them and not drives yet.
    public static func unclaimedVolumes(
        inList plist: [String: Any],
        info: (String) -> [String: Any]
    ) -> [Drive] {
        rows(inList: plist, info: info, claimed: false)
    }

    private static func rows(
        inList plist: [String: Any],
        info: (String) -> [String: Any],
        claimed: Bool
    ) -> [Drive] {
        guard let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }

        var drives: [Drive] = []
        for disk in allDisks {
            let wholeIdent = disk["DeviceIdentifier"] as? String
            let wholeInfo = wholeIdent.map(info) ?? [:]
            // The product name of the physical drive is what a person recognises
            // ("Elements 25A2"), and it is absent from the list plist.
            let product = firstNonEmpty(
                wholeInfo["MediaName"] as? String,
                wholeInfo["IORegistryEntryName"] as? String)
            let bus = wholeInfo["BusProtocol"] as? String
            let internalDisk = wholeInfo["Internal"] as? Bool ?? false
            // diskutil says so twice, and either will do: a bus of "Disk Image"
            // or a virtual disk.
            // The bus, and only the bus: a synthesised APFS container is
            // "Virtual" too, and there are three of those on every Mac.
            let isImage = bus == "Disk Image"

            let partitions = disk["Partitions"] as? [[String: Any]]
            let apfs = disk["APFSVolumes"] as? [[String: Any]]

            // A disk with no partition table at all is one volume filling the
            // whole disk: a stick somebody ran cryptsetup over, a raw image, a
            // BitLocker volume written without a table. diskutil has nothing to
            // say about what is inside one -- an encrypted disk and an empty
            // disk look alike from out here -- so it is offered, and the boot
            // sector settles it when it is chosen. Skipped before, which made
            // exactly those drives invisible.
            // A partition table macOS reads is not always the one that is in
            // use. A stick partitioned on a Mac years ago and formatted NTFS on
            // Windows today still carries the old Apple partition map, and macOS
            // reads that one: it reported a 4 MB Apple_HFS volume and nothing
            // else, so every row for a 123 GB NTFS stick was thrown away and the
            // app showed no drive for a stick that was plugged in.
            //
            // The guest reads tables macOS will not, so where nothing on a disk
            // is a type this app opens, the disk itself is offered as a
            // candidate and the engine is left to find what is on it. Only as a
            // candidate: whether it becomes a row is decided further up, by
            // whether anything on the disk turned out to be openable and whether
            // macOS is using any of it.
            let noneClaimable = !(partitions ?? []).contains {
                VolumeKind.holding(($0["Content"] as? String) ?? "") != nil
            }
            let wholeDiskRow = [
                [
                    "DeviceIdentifier": wholeIdent ?? "", "Content": "",
                    "Size": disk["Size"] ?? 0,
                ]
            ]
            // A disk with no table at all belongs to the list, and only to the
            // list: it is already offered there, and offering it a second time
            // as a leftover put two rows with one identity into the same list,
            // where one hid the other.
            var unpartitioned: [[String: Any]] = []
            if claimed, partitions == nil, apfs == nil, !internalDisk {
                unpartitioned = wholeDiskRow
            } else if !claimed, apfs == nil, !internalDisk, noneClaimable,
                partitions?.isEmpty == false
            {
                unpartitioned = wholeDiskRow
            }

            for part in (partitions ?? []) + unpartitioned {
                guard let ident = part["DeviceIdentifier"] as? String else { continue }
                // "Microsoft Basic Data" covers BitLocker and plain NTFS alike;
                // Linux types cover LUKS and unencrypted Linux filesystems.
                // Nothing can be distinguished further without reading the
                // header, which needs root, so the UI stays honest about it.
                let content = (part["Content"] as? String) ?? ""
                let isWholeDisk = ident == wholeIdent
                // An unpartitioned disk has no type to go by. Linux, because a
                // whole disk handed to cryptsetup is what makes one, and the
                // probe corrects it either way.
                let declared = isWholeDisk ? VolumeKind.linux : VolumeKind.holding(content)
                let kind: VolumeKind
                if claimed {
                    guard let declared else { continue }
                    kind = declared
                } else {
                    // The leftovers: a partition on an external disk whose type
                    // this app makes nothing of, or the whole disk of one where
                    // no partition is a type it opens. Called Linux the way an
                    // unpartitioned disk is -- a neutral guess the first sector
                    // overrules -- and marked as telling us nothing, so no row
                    // claims a format nobody has read.
                    guard !internalDisk, isWholeDisk || declared == nil else { continue }
                    kind = .linux
                }

                let partInfo = info(ident)
                let size =
                    (part["Size"] as? NSNumber)?.int64Value
                    ?? (partInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0

                // Never the partition type. `IORegistryEntryName` for a
                // partition is the type -- "Windows_NTFS" -- and a nameless
                // NTFS stick was listed under it, which is a category in
                // diskutil's spelling and not a name anybody gave the drive.
                let label =
                    firstNonEmpty(
                        named(part["VolumeName"] as? String),
                        named(partInfo["VolumeName"] as? String),
                        named(product),
                        named(partInfo["IORegistryEntryName"] as? String)) ?? ident

                // Where the thing lives, in the words Disk Utility uses for
                // it: Internal, External, or Disk Image. A container file that
                // has been attached is a drive in every way that matters here,
                // so it is listed like one and only named differently.
                var connection: [String] = []
                if isImage {
                    connection.append(appString("Disk Image"))
                } else {
                    if let bus, !bus.isEmpty { connection.append(bus) }
                    connection.append(
                        internalDisk ? appString("Internal") : appString("External"))
                }

                // What this volume is, across ports and replugging. The list
                // plist carries the UUID too, and is the fallback when
                // `diskutil info` on a single partition comes back without it.
                //
                // A partition table written by Windows has no UUID in it at
                // all: MBR predates the idea. Such a drive was identified by
                // diskNsM, which macOS hands out in the order things are
                // plugged in -- so a saved passphrase was stored against
                // disk4s1 and looked for under disk5s1 after the drive was
                // taken out and put back, and the app asked for it again.
                //
                // Where there is no UUID, the drive is named by what does not
                // change: the medium's own name, its size, and where the
                // partition begins on it.
                let uuid =
                    firstNonEmpty(
                        partInfo["DiskUUID"] as? String,
                        partInfo["VolumeUUID"] as? String,
                        part["DiskUUID"] as? String,
                        part["VolumeUUID"] as? String)
                    ?? (isImage
                        ? nil
                        : stableName(
                            media: firstNonEmpty(
                                wholeInfo["MediaName"] as? String,
                                wholeInfo["IORegistryEntryName"] as? String),
                            size: size,
                            offset: (partInfo["PartitionMapPartitionOffset"] as? NSNumber)?
                                .int64Value
                                ?? (part["PartitionMapPartitionOffset"] as? NSNumber)?.int64Value))
                    ?? ident
                drives.append(
                    Drive(
                        id: ident,
                        devicePath: "/dev/\(ident)",
                        name: label,
                        sizeBytes: size,
                        connection: connection.joined(separator: " · "),
                        kind: kind,
                        uuid: uuid,
                        kindIsKnown: claimed && !isWholeDisk))
            }
        }
        return drives
    }

    /// The name, unless it is a partition type wearing one.
    ///
    /// diskutil reports a partition's type as its registry name, so a volume
    /// nobody named came back called "Windows_NTFS" or "Linux_Filesystem".
    /// Those are the strings `VolumeKind.holding` reads, plus the Apple and EFI
    /// ones that reach the same place, and none of them is a name.
    public static func named(_ value: String?) -> String? {
        guard let value else { return nil }
        return isAPartitionType(value) ? nil : value
    }

    /// Whether this string is a partition type rather than a name.
    public static func isAPartitionType(_ value: String) -> Bool {
        [
            "Microsoft Basic Data", "Windows_NTFS", "Windows_FAT_32",
            "Windows_FAT_16", "Windows_Recovery", "Linux Filesystem",
            "Linux_Filesystem", "Linux", "Linux LVM", "Linux_LVM", "Linux RAID",
            "Linux_RAID", "Linux_Swap", "Apple_HFS", "Apple_APFS", "Apple_Boot",
            "Apple_partition_map", "Apple_partition_scheme", "EFI",
            "EFI System Partition", "FDisk_partition_scheme",
            "GUID_partition_scheme",
        ].contains(value)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return nil
    }

    public static func info(for ident: String) -> [String: Any]? {
        runPlist(["/usr/sbin/diskutil", "info", "-plist", ident])
    }

    private static func runPlist(_ argv: [String]) -> [String: Any]? {
        guard let result = run(argv[0], Array(argv.dropFirst())),
            let data = result.out.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return nil }
        return plist as? [String: Any]
    }
}

/// How many drives this Mac can serve at once, and why that is the number.
///
/// Every open drive is a small virtual machine serving NFS to this Mac, and NFS
/// has one port. Two servers cannot share it, so each machine needs an address
/// of its own -- and the addresses are the loopback interface's. A Mac has
/// three out of the box: 127.0.0.1, ::1 and fe80::1. That is the whole limit,
/// and nothing else comes close: an open drive costs about 30 MB of memory and
/// three processes, so memory would not object until there were hundreds.
///
/// More addresses can be added to the loopback interface, which is what the
/// privileged helper does on the app's behalf. They cost nothing -- a kernel
/// entry each, no process and no memory -- so the number is a decision rather
/// than a constraint.
public enum Capacity {
    /// What the app asks the helper to prepare for.
    ///
    /// A dozen. Nobody plugs in twelve encrypted drives at once, and the room
    /// costs nothing, so the number is chosen to be past where anybody will go
    /// rather than close to it.
    public static let wanted = 12

    /// The loopback addresses a drive's virtual machine can be served on.
    ///
    /// Read from the interface rather than remembered, because the answer moves:
    /// the engine adds an address when it mounts as root and leaves it there, so
    /// the same Mac allows three one day and four the next.
    public static func addresses(of interface: String = "lo0") -> [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return found }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let name = entry.pointee.ifa_name, String(cString: name) == interface,
                let address = entry.pointee.ifa_addr
            else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if !found.contains(text) { found.append(text) }
        }
        return found
    }

    /// The loopback addresses a drive can be served on: IPv4 only, which is
    /// what the engine exports over.
    public static func addressesForServing(of interface: String = "lo0") -> [String] {
        addresses(of: interface).filter { $0.contains(".") && !$0.contains(":") }
    }

    /// The highest `127.0.0.x` this app will ever add, and therefore the
    /// highest it must take away again. The two were written separately and
    /// disagreed: adding could reach .63 and releasing stopped at .13, which
    /// would have left addresses on the interface after an uninstall.
    public static let lastLoopbackAddress = 2 + 32

    /// How many drives can be open at once, and how many are.
    ///
    /// The limit can be pinned by the environment, which is how the ceiling is
    /// exercised without opening a dozen drives to get to it. Never read from
    /// anything a person can set by accident: an environment variable set for a
    /// test run, and nothing in the settings.
    /// Named as counts because that is what they are, and because the string
    /// extractor reads the specifier from the name while Foundation reads it
    /// from the type. Where those two disagree the key in the catalogue is not
    /// the key the app looks up, and every translation of it is skipped in
    /// silence -- the English shows, because the key is the English.
    public static func now(mounts: Int) -> (limitCount: Int, openCount: Int) {
        // Only the addresses a drive can actually be served on. The engine
        // exports over IPv4, and lo0 carries ::1 and fe80::1 as well -- counting
        // those said this Mac could open two more drives than it has anywhere to
        // put, so the last one failed to get an address while the app still
        // showed room for it.
        let real = max(1, addressesForServing().count)
        let pinned = ProcessInfo.processInfo.environment["LUKOTTA_CAPACITY"].flatMap(Int.init)
        return (limitCount: pinned.map { max(1, min($0, real)) } ?? real, openCount: max(0, mounts))
    }

    /// Whether another drive can be opened at all.
    public static func hasRoom(limitCount: Int, openCount: Int) -> Bool {
        openCount < limitCount
    }
}
