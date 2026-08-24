// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Every disk attached to this Mac, and what can be done with each.
///
/// The drive list shows only what this application can open, which is correct
/// until it shows nothing: "no encrypted drives found" says nothing about the
/// drive on the desk. This is the other view, listing everything attached with
/// a reason beside each disk that cannot be opened.
public enum DriveSurvey {

    public enum Verdict: Equatable, Sendable {
        /// This app can open it.
        case openable
        /// macOS reads it already, and has it mounted here.
        case macOSHasIt(String)
        /// macOS reads it, but has not mounted it.
        case macOSReadsIt
        /// Part of the running system, not something to open.
        case system
        /// Nothing here can read it.
        case unreadable
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let disk: String
        public let name: String
        public let sizeBytes: Int64
        public let content: String
        public let verdict: Verdict
        /// The drive to open, when there is one.
        public let drive: Drive?

        public init(
            id: String, disk: String, name: String, sizeBytes: Int64, content: String,
            verdict: Verdict, drive: Drive?
        ) {
            self.id = id
            self.disk = disk
            self.name = name
            self.sizeBytes = sizeBytes
            self.content = content
            self.verdict = verdict
            self.drive = drive
        }

        public var sizeDescription: String {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f.string(fromByteCount: sizeBytes)
        }
    }

    /// Partition types belonging to the running system rather than to user
    /// data. Offering them would invite someone to open their own boot disk.
    static let systemContent: Set<String> = [
        "Apple_APFS_ISC", "Apple_APFS_Recovery", "Apple_Boot", "EFI",
        "Apple_KernelCoreDump", "Apple_Recovery",
    ]

    /// Volumes APFS makes for its own purposes inside every container.
    ///
    /// Disk Utility hides these, and a list that shows them buries the one
    /// drive somebody plugged in under a dozen rows nobody can act on. They
    /// belong to the system whatever disk they are on: an external disk with
    /// macOS installed has its own Preboot and Recovery.
    static let systemVolumeNames: Set<String> = [
        "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "iSCPreboot",
        "iSCRecovery",
    ]

    /// Types macOS reads for itself.
    static let macOSContent: Set<String> = [
        "Apple_APFS", "Apple_HFS", "Apple_CoreStorage", "Apple_APFS_Container",
    ]

    /// Everything attached, with a verdict each.
    ///
    /// `openable` is answered by the scanner the main list uses, so the two
    /// cannot disagree about what this app will open.
    public static func survey(
        list plist: [String: Any],
        info: (String) -> [String: Any],
        mountTable: String,
        openable: [Drive]
    ) -> [Entry] {
        guard let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        let byIdentifier = Dictionary(openable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [Entry] = []

        for disk in disks {
            guard let whole = disk["DeviceIdentifier"] as? String else { continue }
            let wholeInfo = info(whole)
            let internalDisk = wholeInfo["Internal"] as? Bool ?? false
            // diskutil says so twice, and either will do.
            let isImage =
                (wholeInfo["BusProtocol"] as? String) == "Disk Image"
                || (wholeInfo["VirtualOrPhysical"] as? String) == "Virtual"
            let product =
                (wholeInfo["MediaName"] as? String) ?? (wholeInfo["IORegistryEntryName"] as? String)

            // A container's volumes are listed under their own key and always
            // belong to macOS.
            let parts = (disk["Partitions"] as? [[String: Any]]) ?? []
            let volumes = (disk["APFSVolumes"] as? [[String: Any]]) ?? []

            for part in parts + volumes {
                guard let identifier = part["DeviceIdentifier"] as? String else { continue }
                let content = (part["Content"] as? String) ?? ""
                let size = (part["Size"] as? NSNumber)?.int64Value ?? 0
                let label = part["VolumeName"] as? String
                let mount = mountPoint(of: identifier, in: mountTable)

                let verdict: Verdict
                if byIdentifier[identifier] != nil {
                    verdict = .openable
                } else if isImage, mount == nil {
                    // A file this app can always hand to the engine. Whether
                    // anything is inside it is a question for the engine, and
                    // a row with no way to try is worse than an attempt that
                    // says why it failed.
                    verdict = .openable
                } else if systemContent.contains(content) || (internalDisk && content.isEmpty)
                    || systemVolumeNames.contains(label ?? "")
                {
                    verdict = .system
                } else if let mount {
                    verdict = .macOSHasIt(mount)
                } else if VolumeKind.holding(content) != nil {
                    // The scanner would offer this if the drive were readable
                    // from here: an unmounted partition of a type this app
                    // opens. Saying "not a format Lukotta can open" of a
                    // BitLocker drive was the same disagreement twice.
                    verdict = .openable
                } else if macOSContent.contains(content)
                    || volumes.contains(where: {
                        ($0["DeviceIdentifier"] as? String) == identifier
                    })
                {
                    verdict = internalDisk ? .system : .macOSReadsIt
                } else {
                    verdict = .unreadable
                }

                entries.append(
                    Entry(
                        id: identifier,
                        disk: whole,
                        name: nonEmpty(label) ?? nonEmpty(product) ?? identifier,
                        sizeBytes: size,
                        content: nonEmpty(content) ?? identifier,
                        verdict: verdict,
                        drive: byIdentifier[identifier]
                            ?? (isImage && mount == nil
                                ? Drive(
                                    id: identifier, devicePath: "/dev/" + identifier,
                                    name: nonEmpty(label) ?? nonEmpty(product) ?? identifier,
                                    sizeBytes: size, connection: appString("Disk Image"),
                                    kind: VolumeKind.holding(content) ?? .linux,
                                    uuid: identifier)
                                : nil)))
            }

            // A disk with nothing on it at all: a bare container file, or a
            // drive nothing has written a partition table to. Either way it is
            // one volume filling the disk, and whether it holds anything is a
            // question for the boot sector rather than for diskutil, which has
            // nothing to say about it. Writing it off as a format this app
            // cannot open was answering a question nobody had asked.
            if parts.isEmpty && volumes.isEmpty {
                let size = (disk["Size"] as? NSNumber)?.int64Value ?? 0
                let mount = mountPoint(of: whole, in: mountTable)
                let verdict: Verdict
                if let drive = byIdentifier[whole], drive.id == whole {
                    verdict = .openable
                } else if internalDisk {
                    verdict = .system
                } else if let mount {
                    verdict = .macOSHasIt(mount)
                } else {
                    verdict = .openable
                }
                entries.append(
                    Entry(
                        id: whole,
                        disk: whole,
                        name: nonEmpty(product) ?? whole,
                        sizeBytes: size,
                        content: nonEmpty(disk["Content"] as? String) ?? whole,
                        verdict: verdict,
                        drive: byIdentifier[whole]
                            ?? Drive(
                                id: whole, devicePath: "/dev/" + whole,
                                name: nonEmpty(product) ?? whole, sizeBytes: size,
                                connection: isImage
                                    ? appString("Disk Image")
                                    : (internalDisk
                                        ? appString("Internal") : appString("External")),
                                kind: .linux, uuid: whole)))
            }
        }
        return entries
    }

    /// What diskutil said, where it said anything.
    ///
    /// It answers with an empty string as readily as it leaves a key out, and
    /// `??` falls through a missing value but not an empty one. A whole disk
    /// with no partition table reports `Content` as "", which reached the list
    /// as a row carrying a size and nothing else: no word for what it is and
    /// none for what it holds.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    /// "/dev/disk5s1 on /Volumes/NAME (…)"
    public static func mountPoint(of identifier: String, in table: String) -> String? {
        MountTableEntry.all(in: table)
            .first { $0.source == "/dev/" + identifier }?.mountPoint
    }
}

extension DriveSurvey {
    /// Everything `diskutil` knows about, including what this app cannot open.
    public static func diskutilList() -> [String: Any] {
        run(["/usr/sbin/diskutil", "list", "-plist"])
    }

    private static func run(_ argv: [String]) -> [String: Any] {
        guard let result = LukottaCore.run(argv[0], Array(argv.dropFirst())),
            let data = result.out.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }
}
