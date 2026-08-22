import Foundation

/// A VHD footer, read far enough to decide what kind of VHD this is.
///
/// A **fixed** VHD is the raw disk followed by a 512-byte footer: every
/// partition table and superblock sits at its natural offset, and the footer is
/// simply past the end. So any engine opens one as-is — it reads it as a raw
/// image and never looks at the last sector.
///
/// A **dynamic** VHD stores its data in blocks listed by an allocation table,
/// which an engine built with our driver reads and one without would serve as
/// gibberish. A **differencing** VHD holds only what changed from a parent disk
/// it names, and is refused whatever the engine can do: nothing here opens an
/// image that names another file.
public struct VhdFooter: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        case fixed = 2
        case dynamic = 3
        case differencing = 4
    }

    /// What the disk holds, or nil for a type nobody has defined.
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
            kind: Kind(rawValue: be32(footer, 60)),
            currentSize: be64(footer, 48))
    }

    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ d: Data, _ at: Int) -> UInt64 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

extension DiskImage {
    public static func isVhd(_ url: URL) -> Bool {
        ["vhd", "vhdx"].contains(url.pathExtension.lowercased())
    }

    /// Whether this VHD may be handed to the engine, or why not.
    public static func objection(toVhd url: URL) -> String? {
        // VHDX is a different format entirely, sharing only the name: a header
        // pair, a log to replay, a region table. Nothing here reads it.
        if url.pathExtension.lowercased() == "vhdx" {
            return appString(
                "“\(url.lastPathComponent)” is a VHDX, which \(appName) cannot open. A VHD, a raw image or a qcow2 would work."
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        guard size > Int64(VhdFooter.length) else {
            return appString("“\(url.lastPathComponent)” is not a disk image this app can read.")
        }
        try? handle.seek(toOffset: UInt64(size) - UInt64(VhdFooter.length))
        guard let bytes = try? handle.read(upToCount: VhdFooter.length),
            let footer = VhdFooter.parse(bytes)
        else {
            return appString("“\(url.lastPathComponent)” is not a disk image this app can read.")
        }

        switch footer.kind {
        case .fixed:
            break
        case .dynamic:
            // Read by the driver we wrote for the engine. A build without it
            // would take the file as raw and find nothing but the header.
            guard EnginePaths.opensVdiAndVhd else {
                return appString(
                    "“\(url.lastPathComponent)” is a dynamic VHD, which this build of the drive engine cannot open. A fixed VHD, a raw image or a qcow2 would work."
                )
            }
        case .differencing:
            return appString(
                "“\(url.lastPathComponent)” holds only the changes from another disk, which it names. \(appName) does not open images that name other files."
            )
        case .none:
            return appString("“\(url.lastPathComponent)” is not a disk image this app can read.")
        }

        // A fixed VHD is its data and then the footer, and nothing else. If the
        // arithmetic does not agree, passing it through as raw would serve
        // whatever else is in the file as though it were the disk. A dynamic
        // one is smaller than the disk it stands for — that is the whole point
        // of it — so only the driver can judge that, and it does.
        guard footer.currentSize > 0,
            footer.kind != .fixed
                || footer.currentSize == UInt64(size) - UInt64(VhdFooter.length)
        else {
            return appString(
                "“\(url.lastPathComponent)” does not hold as much as it says it does, so it may be damaged or unfinished."
            )
        }
        return nil
    }
}
