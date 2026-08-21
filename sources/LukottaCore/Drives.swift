import Foundation

// MARK: - Drives

/// What we can tell about a partition before anything is unlocked.
public enum VolumeKind: String, Hashable, Sendable {
    /// GPT "Microsoft Basic Data" — BitLocker or plain NTFS, indistinguishable
    /// until an unlock is attempted.
    case microsoft
    /// A Linux partition — LUKS, or an unencrypted Linux filesystem.
    case linux

    public var summary: String {
        switch self {
        case .microsoft: return appString("BitLocker or NTFS")
        case .linux: return appString("LUKS or Linux filesystem")
        }
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
    public static func scan() -> [Drive] {
        // Disk images are excluded: a real drive is what this is for. Setting
        // LUKOTTA_INCLUDE_IMAGES=1 includes them, which is how the interface is
        // exercised with several drives without owning several drives.
        var argv = ["/usr/sbin/diskutil", "list", "-plist"]
        if ProcessInfo.processInfo.environment["LUKOTTA_INCLUDE_IMAGES"] != "1" {
            argv.append("physical")
        }
        guard let plist = runPlist(argv),
            let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var drives: [Drive] = []
        for disk in allDisks {
            let wholeIdent = disk["DeviceIdentifier"] as? String
            let wholeInfo = wholeIdent.flatMap { info(for: $0) } ?? [:]
            // The product name of the physical drive is what a person recognises
            // ("Elements 25A2"), and it is absent from the list plist.
            let product = firstNonEmpty(
                wholeInfo["MediaName"] as? String,
                wholeInfo["IORegistryEntryName"] as? String)
            let bus = wholeInfo["BusProtocol"] as? String
            let internalDisk = wholeInfo["Internal"] as? Bool ?? false

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

                let partInfo = info(for: ident) ?? [:]
                let size =
                    (part["Size"] as? NSNumber)?.int64Value
                    ?? (partInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0

                let label =
                    firstNonEmpty(
                        part["VolumeName"] as? String,
                        partInfo["VolumeName"] as? String,
                        product,
                        partInfo["IORegistryEntryName"] as? String) ?? ident

                var connection: [String] = []
                if let bus, !bus.isEmpty { connection.append(bus) }
                connection.append(
                    internalDisk ? appString("Internal") : appString("External"))

                let uuid =
                    firstNonEmpty(
                        partInfo["DiskUUID"] as? String,
                        partInfo["VolumeUUID"] as? String) ?? ident
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

    private static func info(for ident: String) -> [String: Any]? {
        runPlist(["/usr/sbin/diskutil", "info", "-plist", ident])
    }

    private static func runPlist(_ argv: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return
            (try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil)) as? [String: Any]
    }
}
