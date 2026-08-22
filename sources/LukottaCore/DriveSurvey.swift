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

    /// Types macOS reads for itself.
    static let macOSContent: Set<String> = [
        "Apple_APFS", "Apple_HFS", "Apple_CoreStorage", "Apple_APFS_Container",
    ]

    /// Everything attached, with a verdict each.
    ///
    /// `openable` is asked of the same scanner the main list uses, so the two
    /// can never disagree about what this app is willing to open.
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
            let product =
                (wholeInfo["MediaName"] as? String) ?? (wholeInfo["IORegistryEntryName"] as? String)

            // A container's volumes are listed under their own key, and are
            // always macOS's own.
            let parts = (disk["Partitions"] as? [[String: Any]]) ?? []
            let volumes = (disk["APFSVolumes"] as? [[String: Any]]) ?? []

            for part in parts + volumes {
                guard let identifier = part["DeviceIdentifier"] as? String else { continue }
                let content = (part["Content"] as? String) ?? ""
                let size = (part["Size"] as? NSNumber)?.int64Value ?? 0
                let label = part["VolumeName"] as? String
                let mount = mountPoint(of: identifier, in: mountTable)

                let verdict: Verdict
                if let drive = byIdentifier[identifier] {
                    _ = drive
                    verdict = .openable
                } else if systemContent.contains(content) || (internalDisk && content.isEmpty) {
                    verdict = .system
                } else if let mount {
                    verdict = .macOSHasIt(mount)
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
                        name: label ?? product ?? identifier,
                        sizeBytes: size,
                        content: content.isEmpty ? identifier : content,
                        verdict: verdict,
                        drive: byIdentifier[identifier]))
            }

            // A disk with nothing on it at all: a bare container file, or a
            // drive nothing has written a partition table to.
            if parts.isEmpty && volumes.isEmpty {
                let size = (disk["Size"] as? NSNumber)?.int64Value ?? 0
                entries.append(
                    Entry(
                        id: whole,
                        disk: whole,
                        name: product ?? whole,
                        sizeBytes: size,
                        content: (disk["Content"] as? String) ?? whole,
                        verdict: byIdentifier[whole] != nil ? .openable : .unreadable,
                        drive: byIdentifier[whole]))
            }
        }
        return entries
    }

    /// "/dev/disk5s1 on /Volumes/NAME (…)"
    public static func mountPoint(of identifier: String, in table: String) -> String? {
        for line in table.components(separatedBy: .newlines) {
            guard line.hasPrefix("/dev/" + identifier + " ") else { continue }
            guard let on = line.range(of: " on "),
                let paren = line.range(of: " (", range: on.upperBound..<line.endIndex)
            else { continue }
            return String(line[on.upperBound..<paren.lowerBound])
        }
        return nil
    }
}

extension DriveSurvey {
    /// Everything `diskutil` knows about, including what this app cannot open.
    public static func diskutilList() -> [String: Any] {
        run(["/usr/sbin/diskutil", "list", "-plist"])
    }

    public static func mountTable() -> String {
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

    private static func run(_ argv: [String]) -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any] ?? [:]
    }
}
