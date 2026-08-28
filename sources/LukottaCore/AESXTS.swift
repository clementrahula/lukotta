// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import CommonCrypto
import Foundation

/// AES-XTS, which is how both BitLocker and LUKS encrypt a disk.
///
/// A disk cannot be encrypted the way a message is. Every sector has to be
/// decryptable on its own, without reading the ones before it, and two sectors
/// holding the same bytes must not encrypt to the same ciphertext -- or the
/// shape of a filesystem shows through the encryption. XTS solves both by
/// mixing the sector's number into the cipher: each sector gets a *tweak*
/// derived from its position, so identical plaintext at different offsets comes
/// out different, and any sector can be decrypted alone.
///
/// **macOS does not expose XTS.** `CommonCrypto` documents it in a comment and
/// its mode enum stops at CFB8; CryptoKit has no block-cipher modes at all. So
/// it is built here on AES-ECB, which is the primitive XTS is defined over.
/// That is not a workaround -- XTS *is* two ECB operations and a multiplication
/// in GF(2^128) -- but it is the kind of thing that has to be checked against
/// somebody else's numbers rather than trusted, so it is checked against the
/// IEEE 1619 vectors.
///
/// This is the data path only. Getting the key -- unwrapping BitLocker's FVEK
/// with a recovery password, or deriving LUKS's from a passphrase -- is separate
/// and not here.
public enum AESXTS {

    /// A sector's tweak: its number, as a little-endian 128-bit value.
    ///
    /// Little-endian, and this is the one detail that silently produces
    /// plausible-looking rubbish if it is wrong: the first sector decrypts
    /// correctly either way, because zero is the same in both, and everything
    /// after it does not.
    public static func tweak(forSector sector: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((sector >> (8 * UInt64(i))) & 0xFF) }
        return bytes
    }

    /// One AES-ECB block operation, which is all CommonCrypto is asked for.
    private static func ecb(
        _ operation: Int, key: [UInt8], block: [UInt8]
    ) -> [UInt8]? {
        guard block.count == 16, key.count == 16 || key.count == 24 || key.count == 32 else {
            return nil
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            block.withUnsafeBytes { b in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(
                        CCOperation(operation), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), k.baseAddress, key.count, nil,
                        b.baseAddress, 16, o.baseAddress, 16, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { return nil }
        return out
    }

    /// Multiply the tweak by the primitive element of GF(2^128).
    ///
    /// A shift left by one bit across the whole 128-bit value, and where a bit
    /// falls off the top, exclusive-or with 0x87 at the bottom. That constant is
    /// the reduction polynomial and is not negotiable: any other value decrypts
    /// the first block of every sector correctly and nothing after it.
    public static func doubled(_ tweak: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var carry: UInt8 = 0
        for i in 0..<16 {
            let next = tweak[i] >> 7
            out[i] = (tweak[i] << 1) | carry
            carry = next
        }
        if carry != 0 { out[0] ^= 0x87 }
        return out
    }

    /// Decrypt one sector.
    ///
    /// - Parameters:
    ///   - data: the sector's ciphertext. A whole number of 16-byte blocks;
    ///     disk sectors always are, so ciphertext stealing is not implemented
    ///     and a partial block is refused rather than mishandled.
    ///   - key: the two AES keys, concatenated. 32 bytes for AES-128-XTS,
    ///     64 for AES-256-XTS, which is what BitLocker and LUKS use.
    ///   - sector: the sector's number, which becomes its tweak.
    public static func decrypt(_ data: [UInt8], key: [UInt8], sector: UInt64) -> [UInt8]? {
        guard key.count == 32 || key.count == 64 else { return nil }
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let half = key.count / 2
        let dataKey = Array(key[0..<half])
        let tweakKey = Array(key[half...])

        // The tweak is the sector number encrypted with the second key.
        guard var running = ecb(kCCEncrypt, key: tweakKey, block: tweak(forSector: sector)) else {
            return nil
        }

        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for start in stride(from: 0, to: data.count, by: 16) {
            var block = Array(data[start..<start + 16])
            for i in 0..<16 { block[i] ^= running[i] }
            guard var plain = ecb(kCCDecrypt, key: dataKey, block: block) else { return nil }
            for i in 0..<16 { plain[i] ^= running[i] }
            out.append(contentsOf: plain)
            running = doubled(running)
        }
        return out
    }

    /// Encrypt one sector. Here so the decryption can be checked against it and
    /// against the published vectors from both directions.
    public static func encrypt(_ data: [UInt8], key: [UInt8], sector: UInt64) -> [UInt8]? {
        guard key.count == 32 || key.count == 64 else { return nil }
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let half = key.count / 2
        let dataKey = Array(key[0..<half])
        let tweakKey = Array(key[half...])

        guard var running = ecb(kCCEncrypt, key: tweakKey, block: tweak(forSector: sector)) else {
            return nil
        }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for start in stride(from: 0, to: data.count, by: 16) {
            var block = Array(data[start..<start + 16])
            for i in 0..<16 { block[i] ^= running[i] }
            guard var cipher = ecb(kCCEncrypt, key: dataKey, block: block) else { return nil }
            for i in 0..<16 { cipher[i] ^= running[i] }
            out.append(contentsOf: cipher)
            running = doubled(running)
        }
        return out
    }
}
