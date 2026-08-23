// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A VDI header, read far enough to decide whether the engine should be handed
/// the file.
///
/// VirtualBox's format: a header, a map holding one entry per block of the
/// virtual disk, then the blocks in the order they were written. No part of the
/// disk lies at the offset the disk gives, so the file is read by the engine's
/// VDI driver or not at all.
///
/// A VDI cannot name another file. Its data is always its own, so the rule
/// applied to qcow2 and VMDK has nothing to test here.
public struct VdiHeader: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        /// Only the blocks that were written are in the file.
        case dynamic = 1
        /// Every block is in the file, in order.
        case fixed = 2
    }

    /// What the file holds, or nil for a value the format does not define.
    public let kind: Kind?
    /// How large the virtual disk is.
    public let diskSize: UInt64
    /// The major version that wrote it. Only version 1 was released.
    public let major: UInt32

    /// The signature that begins the header, after 64 bytes of free text.
    public static let signature: UInt32 = 0xbeda_107f
    /// Where that signature sits.
    public static let signatureOffset = 0x40
    /// How much of the file must be read to find all of the above.
    public static let length = 0x200

    public static func parse(_ head: Data) -> VdiHeader? {
        guard head.count >= length, le32(head, signatureOffset) == signature else { return nil }
        return VdiHeader(
            kind: Kind(rawValue: le32(head, 0x4c)),
            diskSize: le64(head, 0x170),
            major: le32(head, 0x44) >> 16)
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 4)].reversed().reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
    }

    private static func le64(_ d: Data, _ at: Int) -> UInt64 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 8)].reversed().reduce(UInt64(0)) {
            $0 << 8 | UInt64($1)
        }
    }
}

extension DiskImage {
    public static func isVdi(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vdi"
    }

    /// Whether this VDI may be handed to the engine, or why not.
    public static func objection(toVdi url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: VdiHeader.length),
            let header = VdiHeader.parse(bytes)
        else {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }

        // Version 0 laid the header out differently. Reading such a file as
        // version 1 locates the block map at the wrong offset.
        guard header.major == 1, header.kind != nil, header.diskSize > 0 else {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }

        // An engine built without the VDI driver reads the file as raw, which
        // presents the header as though it were the start of the disk.
        guard EnginePaths.opensVdiAndVhd else {
            return appString(
                "“\(url.lastPathComponent)” is a VDI, which this build of the drive engine cannot open. A raw image or a qcow2 would work."
            )
        }
        return nil
    }
}
