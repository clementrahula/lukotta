import Foundation

/// A VHDX, read far enough to decide whether the engine should be handed it.
///
/// VHDX shares its name with VHD and none of its layout. Locating the disk is
/// the driver's work; what is established here are the two conditions under
/// which the file must not be opened at all.
///
/// A log that is not empty means the image was not closed cleanly. Its most
/// recent state is in that log, so reading the file without replaying it
/// returns data older than the disk last held. Replaying requires writing, and
/// nothing here writes to a disk image.
///
/// A parent makes it a differencing image, holding only the changes from
/// another disk that it names. This application opens no image that names
/// another file.
public struct VhdxHeader: Equatable, Sendable {
    /// Whether the log holds entries yet to be replayed.
    public let dirty: Bool
    /// The number the header carries; of the two, the higher one is live.
    public let sequence: UInt64

    /// What the file begins with.
    public static let signature = Array("vhdxfile".utf8)
    /// Where the two headers sit, one after the other.
    public static let headerOffsets: [UInt64] = [0x1_0000, 0x2_0000]
    /// How long a header is.
    public static let headerLength = 4096
    /// What each header begins with.
    public static let headerSignature = Array("head".utf8)

    /// Read both headers and report on the live one.
    ///
    /// The live header is whichever carries the higher sequence number. The
    /// checksum is verified by the driver rather than here; a header this
    /// cannot parse is left for the driver to reject.
    public static func parse(headers: [Data]) -> VhdxHeader? {
        var live: VhdxHeader?
        for header in headers {
            guard header.count >= headerLength,
                Array(header.prefix(headerSignature.count)) == headerSignature
            else { continue }
            let sequence = le64(header, 8)
            let logGuid = header[header.index(header.startIndex, offsetBy: 48)...].prefix(16)
            let candidate = VhdxHeader(dirty: logGuid.contains { $0 != 0 }, sequence: sequence)
            if live.map({ sequence > $0.sequence }) ?? true { live = candidate }
        }
        return live
    }

    static func le64(_ d: Data, _ at: Int) -> UInt64 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 8)].reversed().reduce(UInt64(0)) {
            $0 << 8 | UInt64($1)
        }
    }

    static func le16(_ d: Data, _ at: Int) -> UInt16 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 2)].reversed().reduce(UInt16(0)) {
            $0 << 8 | UInt16($1)
        }
    }

    static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 4)].reversed().reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
    }

    /// Where the region table sits.
    public static let regionOffset: UInt64 = 0x3_0000
    /// How long it is.
    public static let regionLength = 65536
    /// The region holding the metadata table.
    public static let metadataRegion: [UInt8] = [
        0x06, 0xA2, 0x7C, 0x8B, 0x90, 0x47, 0x9A, 0x4B,
        0xB8, 0xFE, 0x57, 0x5F, 0x05, 0x0F, 0x88, 0x6E,
    ]
    /// The metadata item giving the block size and whether there is a parent.
    public static let fileParameters: [UInt8] = [
        0x37, 0x67, 0xA1, 0xCA, 0x36, 0xFA, 0x43, 0x4D,
        0xB3, 0xB6, 0x33, 0xF0, 0xAA, 0x44, 0xE7, 0x6B,
    ]

    /// Where the metadata region is, according to the region table.
    public static func metadataAt(regionTable: Data) -> UInt64? {
        guard regionTable.count >= 16,
            Array(regionTable.prefix(4)) == Array("regi".utf8)
        else { return nil }
        let count = Int(le32(regionTable, 8))
        guard count <= (regionLength - 16) / 32 else { return nil }
        for i in 0..<count {
            let at = 16 + i * 32
            guard regionTable.count >= at + 32 else { return nil }
            let start = regionTable.index(regionTable.startIndex, offsetBy: at)
            let guid = Array(regionTable[start..<regionTable.index(start, offsetBy: 16)])
            if guid == metadataRegion { return le64(regionTable, at + 16) }
        }
        return nil
    }

    /// Whether the metadata region says this image holds only what changed from
    /// a parent disk it names.
    public static func namesAParent(metadata: Data) -> Bool {
        guard metadata.count >= 32,
            Array(metadata.prefix(8)) == Array("metadata".utf8)
        else { return false }
        // The count is a 16-bit field at 10; 8 is reserved and always zero.
        let count = Int(le16(metadata, 10))
        for i in 0..<count {
            let at = 32 + i * 32
            guard metadata.count >= at + 32 else { return false }
            let start = metadata.index(metadata.startIndex, offsetBy: at)
            let guid = Array(metadata[start..<metadata.index(start, offsetBy: 16)])
            guard guid == fileParameters else { continue }
            let offset = Int(le32(metadata, at + 16))
            guard metadata.count >= offset + 8 else { return false }
            return le32(metadata, offset + 4) & 2 != 0
        }
        return false
    }
}

/// Read `length` bytes at `at`, or nothing if they are not there.
private func read(_ handle: FileHandle, at: UInt64, _ length: Int) -> Data? {
    guard (try? handle.seek(toOffset: at)) != nil,
        let block = try? handle.read(upToCount: length), block.count == length
    else { return nil }
    return block
}

extension DiskImage {
    public static func isVhdx(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vhdx"
    }

    /// Whether this VHDX may be handed to the engine, or why not.
    public static func objection(toVhdx url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: VhdxHeader.signature.count),
            Array(head) == VhdxHeader.signature
        else {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }

        var headers: [Data] = []
        for at in VhdxHeader.headerOffsets {
            guard (try? handle.seek(toOffset: at)) != nil,
                let block = try? handle.read(upToCount: VhdxHeader.headerLength),
                block.count == VhdxHeader.headerLength
            else { continue }
            headers.append(block)
        }
        guard let header = VhdxHeader.parse(headers: headers) else {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }

        if header.dirty {
            return appString(
                "“\(url.lastPathComponent)” was not shut down cleanly, and its most recent contents have not been written back into the file. Open it once in the virtual machine it belongs to, then try again."
            )
        }

        // The driver refuses a differencing image as well. This check exists
        // so that the reason names the file, and does so before the engine is
        // given the path.
        if let table = read(handle, at: VhdxHeader.regionOffset, VhdxHeader.regionLength),
            let metadataAt = VhdxHeader.metadataAt(regionTable: table),
            // The items are stored past the table that lists them, so this
            // reads beyond the first 64 KB of the region.
            let metadata = read(handle, at: metadataAt, 128 * 1024),
            VhdxHeader.namesAParent(metadata: metadata)
        {
            return appString(
                "“\(url.lastPathComponent)” holds only the changes from another disk, which it names. \(appName) does not open images that name other files."
            )
        }

        // An engine built without the VHDX driver reads the file as raw, which
        // presents the header as though it were the start of the disk.
        guard EnginePaths.opensVdiAndVhd else {
            return appString(
                "“\(url.lastPathComponent)” is a VHDX, which this build of the drive engine cannot open. A VHD, a raw image or a qcow2 would work."
            )
        }
        return nil
    }
}
