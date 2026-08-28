// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The shape of an NTFS volume, read from its first sector.
///
/// `BootSector.identify` answers *what* a volume is. This answers *where things
/// are on it*, which is the first thing anything reading NTFS has to know: how
/// big a cluster is, how many there are, and where the master file table starts.
/// Everything else on the volume is found through the MFT, and the MFT is found
/// through this.
///
/// Every field is little-endian and at a fixed offset in the 512-byte boot
/// sector, unchanged since NT 3.1. The layout is documented by Microsoft and
/// implemented identically by ntfs-3g and the Linux ntfs3 driver.
///
/// **Refusing is the important half.** These numbers come off a disk somebody
/// plugged in, so they are input, not fact. A cluster size of zero divides by
/// zero; a huge one makes an allocation that never returns; an MFT beyond the
/// end of the volume reads somebody else's disk. Every one of them is checked
/// against what NTFS actually permits, and a volume that fails is not opened
/// rather than opened wrongly.
public struct NTFSGeometry: Sendable, Equatable {

    /// Bytes in a sector. 512 on every drive NTFS has shipped on, but 4096
    /// exists and the field is there to be read rather than assumed.
    public let bytesPerSector: Int
    /// Sectors in a cluster. A power of two, 1 to 128.
    public let sectorsPerCluster: Int
    /// Sectors in the whole volume, as the boot sector claims.
    public let totalSectors: UInt64
    /// Which cluster the master file table starts at.
    public let mftStartCluster: UInt64
    /// Which cluster the backup master file table starts at.
    public let mftMirrorStartCluster: UInt64
    /// Bytes in one MFT record. Almost always 1024.
    public let bytesPerFileRecord: Int
    /// The volume's serial number, as NTFS writes it.
    public let serialNumber: UInt64

    public var bytesPerCluster: Int { bytesPerSector * sectorsPerCluster }
    public var mftByteOffset: UInt64 { mftStartCluster * UInt64(bytesPerCluster) }
    public var totalBytes: UInt64 { totalSectors * UInt64(bytesPerSector) }

    /// What NTFS permits, and nothing wider.
    ///
    /// Not defensive programming for its own sake: these are the numbers that
    /// turn a corrupt or hostile boot sector into a crash, a hang, or a read of
    /// a neighbouring volume.
    private static let sectorSizes = [512, 1024, 2048, 4096]
    private static let maximumSectorsPerCluster = 128
    private static let maximumBytesPerCluster = 2 * 1024 * 1024

    /// Read it, or refuse.
    ///
    /// - Returns: nil when the sector is not NTFS, is too short, or claims
    ///   something NTFS does not permit. Never a half-read answer: a caller
    ///   that gets a value can use every field of it.
    public static func read(_ sector: Data) -> NTFSGeometry? {
        guard sector.count >= 512 else { return nil }
        guard BootSector.identify(sector) == .ntfs else { return nil }

        let base = sector.startIndex
        func byte(_ offset: Int) -> Int { Int(sector[base + offset]) }
        func word(_ offset: Int) -> Int {
            byte(offset) | (byte(offset + 1) << 8)
        }
        func quad(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in (0..<8).reversed() { value = (value << 8) | UInt64(byte(offset + i)) }
            return value
        }

        let bytesPerSector = word(0x0B)
        guard sectorSizes.contains(bytesPerSector) else { return nil }

        let sectorsPerCluster = byte(0x0D)
        guard sectorsPerCluster > 0, sectorsPerCluster <= maximumSectorsPerCluster,
            sectorsPerCluster & (sectorsPerCluster - 1) == 0
        else { return nil }

        let bytesPerCluster = bytesPerSector * sectorsPerCluster
        guard bytesPerCluster <= maximumBytesPerCluster else { return nil }

        let totalSectors = quad(0x28)
        guard totalSectors > 0 else { return nil }

        let mft = quad(0x30)
        let mftMirror = quad(0x38)
        // The MFT lives on the volume. One that claims otherwise would have us
        // reading past the end of the partition, which on a whole disk means
        // reading the next volume along.
        let totalClusters = totalSectors / UInt64(sectorsPerCluster)
        guard mft < totalClusters, mftMirror < totalClusters else { return nil }

        // A signed byte: positive is clusters per record, negative is a power of
        // two in bytes. Both spellings are in the wild -- 1024-byte records on a
        // 4096-byte cluster volume are written the second way.
        let raw = Int8(bitPattern: sector[base + 0x40])
        let bytesPerFileRecord: Int
        if raw > 0 {
            bytesPerFileRecord = Int(raw) * bytesPerCluster
        } else {
            let shift = Int(-raw)
            guard shift >= 1, shift <= 31 else { return nil }
            bytesPerFileRecord = 1 << shift
        }
        // A record holds a header and attributes; smaller than a sector is not a
        // record, and larger than a cluster run is a number nobody writes.
        guard bytesPerFileRecord >= 256, bytesPerFileRecord <= maximumBytesPerCluster else {
            return nil
        }

        return NTFSGeometry(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            totalSectors: totalSectors,
            mftStartCluster: mft,
            mftMirrorStartCluster: mftMirror,
            bytesPerFileRecord: bytesPerFileRecord,
            serialNumber: quad(0x48))
    }
}
