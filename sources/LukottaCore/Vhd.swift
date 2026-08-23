// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A VHD footer, read far enough to establish which of the three forms this is.
///
/// A fixed VHD is the raw disk followed by a 512-byte footer. Every partition
/// table and superblock lies at its natural offset and the footer sits past the
/// end of the disk, so any engine opens one as a raw image without reading the
/// last sector.
///
/// A dynamic VHD stores its data in blocks listed by an allocation table, which
/// an engine carrying the VHD driver reads and one without it cannot. A
/// differencing VHD holds only the changes from a parent disk that it names,
/// and is refused whatever the engine supports, as is every image that names
/// another file.
public struct VhdFooter: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        case fixed = 2
        case dynamic = 3
        case differencing = 4
    }

    /// Which form this is, or nil for a value the format does not define.
    public let kind: Kind?
    /// The virtual disk's size, which for a fixed VHD is the data before the
    /// footer.
    public let currentSize: UInt64

    public static let cookie = Array("conectix".utf8)
    public static let length = 512

    /// Read a footer from the last 512 bytes of a file.
    public static func parse(_ footer: Data) -> VhdFooter? {
        guard footer.count >= length,
            Array(footer.prefix(cookie.count)) == cookie
        else { return nil }
        return VhdFooter(
            kind: Kind(rawValue: footer.be32(at: 60)),
            currentSize: footer.be64(at: 48))
    }
}

extension DiskImage {
    public static func isVhd(_ url: URL) -> Bool {
        // Not "vhdx". That is a separate format with a reader of its own.
        url.pathExtension.lowercased() == "vhd"
    }

    /// Whether this VHD may be handed to the engine, or why not.
    public static func objection(toVhd url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        let size = fileSize(atPath: url.path)
        guard size > Int64(VhdFooter.length) else {
            return appString("“\(url.lastPathComponent)” is not a disk image.")
        }
        try? handle.seek(toOffset: UInt64(size) - UInt64(VhdFooter.length))
        guard let bytes = try? handle.read(upToCount: VhdFooter.length),
            let footer = VhdFooter.parse(bytes)
        else {
            return appString("“\(url.lastPathComponent)” is not a disk image.")
        }

        switch footer.kind {
        case .fixed:
            break
        case .dynamic:
            // An engine built without the VHD driver reads the file as raw,
            // which presents the header as though it were the disk.
            guard EnginePaths.opensVdiAndVhd else {
                return appString(
                    "“\(url.lastPathComponent)” is a dynamic VHD, and this build’s drive engine has no driver for it. A fixed VHD, a raw image or a qcow2 would open."
                )
            }
        case .differencing:
            return appString(
                "“\(url.lastPathComponent)” holds only the changes from another disk, and names the disk it changes."
            )
        case .none:
            return appString("“\(url.lastPathComponent)” is not a disk image.")
        }

        // A fixed VHD holds its data followed by the footer and nothing else.
        // If the arithmetic disagrees, reading it as raw would serve the rest of
        // the file as though it were the disk. A dynamic VHD is smaller than the
        // disk it represents by design, so only the driver can judge its size.
        guard footer.currentSize > 0,
            footer.kind != .fixed
                || footer.currentSize == UInt64(size) - UInt64(VhdFooter.length)
        else {
            return appString(
                "“\(url.lastPathComponent)” is smaller than its footer states, and may be damaged or incomplete."
            )
        }
        return nil
    }
}
