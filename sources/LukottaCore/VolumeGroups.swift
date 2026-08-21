import Foundation

/// A logical volume discovered inside an unlocked container.
public struct LogicalVolume: Equatable, Sendable {
    public let identifier: String  // "lukottavg:disk4s1:root"
    public let label: String  // filesystem label, or the LV name
    public let filesystem: String  // ext4, btrfs, xfs …
    public let size: String

    /// What `anylinuxfs mount` expects for this volume.
    public init(identifier: String, label: String, filesystem: String, size: String) {
        self.identifier = identifier
        self.label = label
        self.filesystem = filesystem
        self.size = size
    }

    public var mountIdentifier: String { "lvm:\(identifier)" }
}

/// Parses `anylinuxfs list --decrypt` output.
///
/// Ubuntu, Debian, Mint, Pop and Fedora all put LVM inside the LUKS container,
/// so unlocking exposes a volume group rather than a filesystem. The engine
/// addresses those as `lvm:<vg>:<disk>:<lv>`, and prints exactly that triple in
/// the IDENTIFIER column:
///
///     lvm:lukottavg (volume group):
///        #:            TYPE NAME             SIZE       IDENTIFIER
///        0:     LVM2_scheme                  +0.6 GB    lukottavg
///                          Physical Store luks-lvm.img
///        1:           btrfs LUKOTTATEST      608.2 MB   lukottavg:luks-lvm.img:data
public enum VolumeGroupParser {
    /// Container types that are not themselves mountable.
    private static let containers: Set<String> = [
        "LVM2_scheme", "LVM2_member", "crypto_LUKS", "GUID_partition_scheme",
        "linux_raid_member", "swap",
    ]

    public static func logicalVolumes(in text: String) -> [LogicalVolume] {
        var found: [LogicalVolume] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // A mountable row ends in vg:disk:lv and begins with an index.
            guard let identifier = fields.last,
                identifier.split(separator: ":").count == 3,
                let first = fields.first, first.hasSuffix(":"),
                Int(first.dropLast()) != nil,
                fields.count >= 4
            else { continue }

            let filesystem = fields[1]
            guard !containers.contains(filesystem) else { continue }

            // NAME may be absent when the filesystem carries no label.
            let sizeIndex = fields.count - 3
            let label = fields.count >= 5 ? fields[2] : ""
            let size = "\(fields[sizeIndex]) \(fields[sizeIndex + 1])"
            let lvName = identifier.split(separator: ":").last.map(String.init) ?? identifier
            found.append(
                LogicalVolume(
                    identifier: identifier,
                    label: label.isEmpty ? lvName : label,
                    filesystem: filesystem,
                    size: size))
        }
        return found
    }
}
