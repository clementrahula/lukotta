// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Reading enough of a qcow2 header to decide whether it is safe to open.
///
/// A qcow2 can name other files: a backing file it was derived from, or an
/// external data file holding the guest's clusters. libkrun opens them, as its
/// own header states: "formats other than raw can reference other files that
/// libkrun will automatically open". A file handed to this application can
/// therefore determine which other files the virtual machine reads.
///
/// Container files are opened without privilege, which limits that reach to
/// what the person who opened the file could already read. That bounds the
/// consequence rather than justifying it: opening a disk image does not imply
/// consent to it naming a path of its own.
///
/// Field offsets are from the qcow2 specification.
public struct Qcow2Header: Equatable, Sendable {
    public let version: UInt32
    /// Where the name of a backing file is stored, or 0 for none.
    public let backingFileOffset: UInt64
    public let backingFileSize: UInt32
    /// Only present from version 3. Zero when absent.
    public let incompatibleFeatures: UInt64

    public static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]  // QFI\xfb

    /// Guest clusters live in a separate file this one names.
    public static let externalDataFileBit: UInt64 = 1 << 2
    /// The image is marked corrupt and must not be written to.
    public static let corruptBit: UInt64 = 1 << 1

    /// "External data file name", as a header extension.
    public static let externalDataExtension: UInt32 = 0x4441_5441

    public var namesABackingFile: Bool { backingFileOffset != 0 && backingFileSize != 0 }
    public var usesExternalDataFile: Bool { incompatibleFeatures & Self.externalDataFileBit != 0 }
    public var isCorrupt: Bool { incompatibleFeatures & Self.corruptBit != 0 }

    /// Whether opening this would let the image choose another file to read.
    public var namesAnotherFile: Bool { namesABackingFile || usesExternalDataFile }

    /// Parse a header from the front of a qcow2. Nil when it is not one.
    public static func parse(_ bytes: Data) -> Qcow2Header? {
        guard bytes.count >= 72, Array(bytes.prefix(4)) == magic else { return nil }
        let version = bytes.be32(at: 4)
        guard version == 2 || version == 3 else { return nil }
        // Version 2 stops at 72 bytes and has no feature fields.
        let features = version >= 3 && bytes.count >= 80 ? bytes.be64(at: 72) : 0
        return Qcow2Header(
            version: version,
            backingFileOffset: bytes.be64(at: 8),
            backingFileSize: bytes.be32(at: 16),
            incompatibleFeatures: features)
    }

    /// Whether the header extension area names an external data file.
    ///
    /// The feature bit and the extension are meant to agree, and a file that
    /// sets one without the other is exactly the sort of thing to refuse rather
    /// than reason about.
    public static func hasExternalDataExtension(_ bytes: Data) -> Bool {
        // Extensions begin after the header, whose length is at offset 100 in
        // version 3. Anything shorter has none.
        guard bytes.count >= 104 else { return false }
        var offset = Int(bytes.be32(at: 100))
        guard offset >= 104 else { return false }
        while offset + 8 <= bytes.count {
            let type = bytes.be32(at: offset)
            let length = Int(bytes.be32(at: offset + 4))
            if type == 0 { return false }  // end of the extension area
            if type == externalDataExtension { return true }
            // Each extension is padded to a multiple of eight.
            offset += 8 + (length + 7) / 8 * 8
        }
        return false
    }
}

extension DiskImage {
    /// How much of a qcow2 to read before deciding. The header and its
    /// extension area both live in the first cluster.
    static let qcow2HeaderLength = 65536

    /// Whether this qcow2 may be handed to the engine.
    ///
    /// Returns nil when it is fine, or the reason it is not.
    public static func objection(toQcow2 url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(isolated(url.lastPathComponent))” could not be read.")
        }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: qcow2HeaderLength),
            let header = Qcow2Header.parse(bytes)
        else {
            return appString("“\(isolated(url.lastPathComponent))” is not a disk image.")
        }
        if header.namesAnotherFile || Qcow2Header.hasExternalDataExtension(bytes) {
            return appString(
                "“\(isolated(url.lastPathComponent))” names another file on this Mac, which would be opened along with it."
            )
        }
        if header.isCorrupt {
            return appString(
                "“\(isolated(url.lastPathComponent))” is marked as damaged. Repair it before opening it."
            )
        }
        return nil
    }
}
