// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// An encrypted volume, read as though it were not.
///
/// `NTFSVolumeReader` takes one function: bytes at an offset. That was chosen so
/// that what is underneath could change without the reader knowing, and this is
/// the case it was chosen for. Wrap the device's reader in this and the NTFS
/// reader above sees plaintext, without a line of it knowing that a volume can
/// be encrypted at all.
///
/// **The offset arithmetic is where this goes wrong quietly.** A read of forty
/// bytes from the middle of a sector cannot be decrypted on its own: XTS works a
/// sector at a time, keyed to the sector's number. So a read has to be widened
/// to whole sectors, decrypted, and then trimmed back to what was asked for. Get
/// the widening wrong and every read that is not already sector-aligned returns
/// noise -- which on a filesystem means most of them.
///
/// It reads. Writing an encrypted volume means encrypting on the way out, which
/// is the same arithmetic backwards and is not here because there is no write
/// path to put it in.
public final class DecryptingReader: @unchecked Sendable {

    /// Where the encrypted bytes come from.
    private let underlying: NTFSVolumeReader.ReadBytes
    /// The two AES keys, concatenated.
    private let key: [UInt8]
    /// How large a sector is, in bytes. The unit XTS is keyed to.
    private let sectorSize: Int
    /// Where the encrypted region starts on the device.
    ///
    /// A LUKS or BitLocker container has a header before the data, and the
    /// sector numbers XTS is keyed to count from the start of the *encrypted
    /// region*, not from the start of the disk. Counting from the disk gives
    /// every sector the wrong tweak.
    private let dataOffset: UInt64

    public init(
        sectorSize: Int = 512,
        dataOffset: UInt64 = 0,
        key: [UInt8],
        reading underlying: @escaping NTFSVolumeReader.ReadBytes
    ) {
        self.sectorSize = sectorSize
        self.dataOffset = dataOffset
        self.key = key
        self.underlying = underlying
    }

    /// Bytes at an offset, decrypted. The shape `NTFSVolumeReader` wants.
    ///
    /// The offset is within the volume, as the filesystem sees it. Where the
    /// volume sits on the device is this object's business and nobody else's.
    public func read(_ offset: UInt64, _ length: Int) -> Data? {
        guard sectorSize > 0, length > 0, key.count == 32 || key.count == 64 else { return nil }
        guard let first = firstSector(containing: offset) else { return nil }

        let into = Int(offset % UInt64(sectorSize))
        // Whole sectors, because a partial one cannot be decrypted alone.
        let span = (into + length + sectorSize - 1) / sectorSize * sectorSize

        let start = dataOffset + first * UInt64(sectorSize)
        guard let ciphertext = underlying(start, span), !ciphertext.isEmpty else { return nil }
        // A short read at the end of the device is not an error -- but only
        // whole sectors of it can be decrypted.
        let usable = ciphertext.count / sectorSize * sectorSize
        guard usable > 0 else { return nil }

        var plain = Data()
        plain.reserveCapacity(usable)
        for index in 0..<(usable / sectorSize) {
            let from = ciphertext.startIndex + index * sectorSize
            let sector = Array(ciphertext[from..<from + sectorSize])
            guard
                let decrypted = AESXTS.decrypt(
                    sector, key: key, sector: first + UInt64(index))
            else { return nil }
            plain.append(contentsOf: decrypted)
        }

        guard into < plain.count else { return nil }
        let end = min(into + length, plain.count)
        return plain[plain.startIndex + into..<plain.startIndex + end]
    }

    /// Which sector an offset falls in, counted from the start of the encrypted
    /// region.
    func firstSector(containing offset: UInt64) -> UInt64? {
        guard sectorSize > 0 else { return nil }
        return offset / UInt64(sectorSize)
    }
}
