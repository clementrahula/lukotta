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
        case .linux: return "LUKS"
        }
    }

    public var summary: String { summary() }
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

    public init(
        id: String, devicePath: String, name: String, sizeBytes: Int64,
        connection: String, kind: VolumeKind, uuid: String
    ) {
        self.id = id
        self.devicePath = devicePath
        self.name = name
        self.sizeBytes = sizeBytes
        self.connection = connection
        self.kind = kind
        self.uuid = uuid
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
        let all = ProcessInfo.processInfo.environment["LUKOTTA_INCLUDE_IMAGES"] == "1"
        var argv = ["/usr/sbin/diskutil", "list", "-plist"]
        if !all && images.isEmpty { argv.append("physical") }
        guard let plist = runPlist(argv) else { return [] }
        let found = drives(inList: plist, info: { info(for: $0) ?? [:] })
        guard !all, !images.isEmpty else { return found }
        // Everything came back, so the images nobody asked about go now. A
        // partition of disk6 belongs to disk6.
        let physical = Set(
            (runPlist(["/usr/sbin/diskutil", "list", "-plist", "physical"])?["WholeDisks"]
                as? [String]) ?? [])
        return found.filter { drive in
            let whole = wholeDisk(of: drive.id)
            return physical.contains(whole) || images.contains(whole)
        }
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
            let isImage =
                bus == "Disk Image" || (wholeInfo["VirtualOrPhysical"] as? String) == "Virtual"

            guard let partitions = disk["Partitions"] as? [[String: Any]] else { continue }
            for part in partitions {
                guard let ident = part["DeviceIdentifier"] as? String else { continue }
                // "Microsoft Basic Data" covers BitLocker and plain NTFS alike;
                // Linux types cover LUKS and unencrypted Linux filesystems.
                // Nothing can be distinguished further without reading the
                // header, which needs root, so the UI stays honest about it.
                let content = (part["Content"] as? String) ?? ""
                let kind: VolumeKind
                switch content {
                case "Microsoft Basic Data":
                    kind = .microsoft
                case "Linux Filesystem", "Linux_Filesystem",
                    "Linux LVM", "Linux_LVM", "Linux RAID", "Linux_RAID":
                    kind = .linux
                default:
                    continue
                }

                let partInfo = info(ident)
                let size =
                    (part["Size"] as? NSNumber)?.int64Value
                    ?? (partInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0

                let label =
                    firstNonEmpty(
                        part["VolumeName"] as? String,
                        partInfo["VolumeName"] as? String,
                        product,
                        partInfo["IORegistryEntryName"] as? String) ?? ident

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

                // The list plist carries it too, and is the fallback when
                // `diskutil info` on a single partition comes back without it.
                // A drive identified by diskNsM instead is a drive whose saved
                // passphrase and remembered name are lost the next time it is
                // plugged into a different port.
                let uuid =
                    firstNonEmpty(
                        partInfo["DiskUUID"] as? String,
                        partInfo["VolumeUUID"] as? String,
                        part["DiskUUID"] as? String,
                        part["VolumeUUID"] as? String) ?? ident
                drives.append(
                    Drive(
                        id: ident,
                        devicePath: "/dev/\(ident)",
                        name: label,
                        sizeBytes: size,
                        connection: connection.joined(separator: " · "),
                        kind: kind,
                        uuid: uuid))
            }
        }
        return drives
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
