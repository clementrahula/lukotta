// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A logical volume discovered inside an unlocked container.
public struct LogicalVolume: Equatable, Sendable {
    public let identifier: String  // "lukottavg:disk4s1:root", or "diskA:diskB"
    public let label: String  // filesystem label, or the LV name
    public let filesystem: String  // ext4, btrfs, xfs …
    public let size: String

    /// Which scheme addresses this volume: `lvm` or `raid`.
    ///
    /// It cannot be worked out from the identifier, which is the reason this
    /// is carried rather than derived. An LVM volume is `vg:disk:lv` -- three
    /// parts -- and a RAID array is its member disks, which is two parts for a
    /// mirror and three for an array of three. `disk7s1:disk8s1:disk9s1` and
    /// `ubuntuvg:disk4s1:home` are the same shape and mean entirely different
    /// things, so counting colons picks the wrong one on any array with three
    /// members. The listing says which it is in the section header above the
    /// row, and that is what decides it.
    public let scheme: String

    /// What `anylinuxfs mount` expects for this volume.
    public init(
        identifier: String, label: String, filesystem: String, size: String,
        scheme: String = "lvm"
    ) {
        self.identifier = identifier
        self.label = label
        self.filesystem = filesystem
        self.size = size
        self.scheme = scheme
    }

    public var mountIdentifier: String { "\(scheme):\(identifier)" }
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

    /// "MB", "GiB", "B" — a size unit standing on its own, rather than a word
    /// of the name or a size printed as a single field.
    private static func isSizeUnit(_ field: String) -> Bool {
        guard field.count <= 3, field.hasSuffix("B") || field.hasSuffix("b") else { return false }
        let head = field.dropLast()
        if head.isEmpty { return true }
        if head == "i" { return false }
        let prefix = head.hasSuffix("i") ? head.dropLast() : head
        return prefix.count == 1 && "KMGTPEZ".contains(prefix.uppercased())
    }

    public static func logicalVolumes(in text: String) -> [LogicalVolume] {
        var found: [LogicalVolume] = []
        // Which section the rows below belong to. The listing announces it:
        //
        //     lvm:lukottavg (volume group):
        //     raid:raid1a.img:raid1b.img (volume):
        //
        // and everything indexed underneath is addressed that way. Defaults to
        // lvm, which is what every listing held before RAID was read at all.
        var scheme = "lvm"
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("):"), trimmed.contains(" (") {
                if trimmed.hasPrefix("raid:") { scheme = "raid" }
                if trimmed.hasPrefix("lvm:") { scheme = "lvm" }
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // A mountable row begins with an index and ends with the identifier
            // the section's scheme addresses. LVM prints vg:disk:lv; RAID
            // prints the member disks, of which there are at least two.
            let parts = fields.last?.split(separator: ":").count ?? 0
            guard let identifier = fields.last,
                scheme == "raid" ? parts >= 2 : parts == 3,
                let first = fields.first, first.hasSuffix(":"),
                Int(first.dropLast()) != nil,
                fields.count >= 4
            else { continue }

            let filesystem = fields[1]
            guard !containers.contains(filesystem) else { continue }

            // Where the size begins. It is printed as a number and a unit today
            // ("608.2 MB"), and this counted three fields back from the end on
            // that basis. A size printed as one field would have shifted every
            // name by one and taken the type in with it, so the unit is looked
            // for rather than counted on.
            let unit = fields.count >= 3 ? fields[fields.count - 2] : ""
            let sizeStart = isSizeUnit(unit) ? fields.count - 3 : fields.count - 2
            guard sizeStart >= 2 else { continue }
            let size = fields[sizeStart..<(fields.count - 1)].joined(separator: " ")
            // NAME may be absent when the filesystem carries no label, and may
            // be more than one word when it is not.
            let label = fields[2..<sizeStart].joined(separator: " ")
            let lvName = identifier.split(separator: ":").last.map(String.init) ?? identifier
            found.append(
                LogicalVolume(
                    identifier: identifier,
                    label: label.isEmpty ? lvName : label,
                    filesystem: filesystem,
                    size: size,
                    scheme: scheme))
        }
        return found
    }
}
