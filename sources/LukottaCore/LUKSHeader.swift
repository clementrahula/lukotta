// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// How much memory unlocking a LUKS volume will actually ask for.
///
/// The engine gives every LUKS mount 2560 MiB, whatever the volume is, because
/// cryptsetup can want a great deal and the header is the only thing that says
/// how much. It is not a wrong number so much as an unasked question: a default
/// `cryptsetup luksFormat` on this machine wrote a header asking for 221 MiB,
/// and the machine was given eleven times that.
///
/// The cost is not the memory itself -- it is lazily backed and mostly untouched
/// -- but that it is the ceiling every other figure is derived from, and that a
/// second encrypted drive wants another one. Twelve of them at 2560 is a number
/// no laptop has.
///
/// So the header is read. LUKS2 records the KDF's memory cost per keyslot, in
/// kibibytes, and the largest of them is what an unlock can be asked to find.
/// LUKS1 has no such cost at all: it uses PBKDF2, which is iterations and a hash
/// and no arena to allocate.
public enum LUKSHeader {

    /// "LUKS" and two bytes, at the very start. Both versions write it.
    public static let magic: [UInt8] = [0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE]

    /// Where the JSON metadata begins in a LUKS2 header, by the format's
    /// definition rather than by anything read out of the header itself.
    public static let jsonOffset = 4096

    /// A header is worth reading this far in. The JSON area is 12 KiB in the
    /// default layout and the size field says the rest; this is the ceiling on
    /// how much is asked for before that field has been read.
    public static let bytesToRead = 1 << 20

    /// What the header says, or nil when these bytes are not one.
    public struct Requirement: Equatable, Sendable {
        /// 1 or 2.
        public let version: Int
        /// The largest KDF memory cost across the keyslots, in MiB. Zero for
        /// LUKS1, and for a LUKS2 header whose keyslots name no cost.
        public let kdfMiB: Int
    }

    /// Read it, tolerantly.
    ///
    /// Every way this can fail answers nil, and nil means "cannot say" rather
    /// than "needs nothing": the caller keeps the engine's own floor when it
    /// gets one. A header that is truncated, unparseable, or a version this
    /// does not know is exactly the case where guessing low would turn an
    /// unlock that works into one that is killed for want of memory.
    public static func read(_ bytes: Data) -> Requirement? {
        guard bytes.count >= 8, Array(bytes.prefix(magic.count)) == magic else { return nil }
        let version = Int(bytes[bytes.startIndex + 6]) << 8 | Int(bytes[bytes.startIndex + 7])
        switch version {
        case 1:
            // PBKDF2. Iterations and a hash, and nothing to allocate.
            return Requirement(version: 1, kdfMiB: 0)
        case 2:
            guard let json = jsonArea(bytes) else { return nil }
            return Requirement(version: 2, kdfMiB: largestKdfMiB(json))
        default:
            return nil
        }
    }

    /// The JSON metadata, as bytes.
    ///
    /// It is NUL-padded to fill the area it sits in, so it is cut at the first
    /// NUL rather than handed to the parser whole.
    static func jsonArea(_ bytes: Data) -> Data? {
        guard bytes.count > jsonOffset else { return nil }
        let start = bytes.index(bytes.startIndex, offsetBy: jsonOffset)
        let area = bytes[start...]
        guard let end = area.firstIndex(of: 0) else { return area.isEmpty ? nil : area }
        return end == area.startIndex ? nil : area[..<end]
    }

    /// The largest `kdf.memory` across the keyslots, converted to MiB.
    ///
    /// The largest, not the first: any keyslot can unlock the volume, and which
    /// one the passphrase belongs to is not known until it is tried. Sizing to
    /// the smallest would work until somebody used their other password.
    ///
    /// Rounded up, because a cost of one and a half MiB that is given one is a
    /// cost that is not met.
    static func largestKdfMiB(_ json: Data) -> Int {
        guard let any = try? JSONSerialization.jsonObject(with: json),
            let top = any as? [String: Any],
            let keyslots = top["keyslots"] as? [String: Any]
        else { return 0 }
        var largestKiB = 0
        for (_, slot) in keyslots {
            guard let slot = slot as? [String: Any],
                let kdf = slot["kdf"] as? [String: Any],
                let memory = kdf["memory"] as? Int
            else { continue }
            largestKiB = max(largestKiB, memory)
        }
        return (largestKiB + 1023) / 1024
    }

    /// The machine's memory, in MiB, for a volume with this requirement.
    ///
    /// The arena the KDF allocates, on top of everything the machine needs
    /// anyway, plus a quarter of the arena again. The quarter is for what
    /// cryptsetup holds beside the arena while it works, and for a header
    /// written by a machine slightly less generous than the one reading it; it
    /// is not a figure anybody measured, which is why it is a proportion rather
    /// than a number and why the floor below it exists.
    ///
    /// Never less than `base`, and never less than the engine would have used
    /// when the header cannot be read at all.
    public static func ramMiB(for requirement: Requirement?, base: Int) -> Int {
        guard let requirement, requirement.kdfMiB > 0 else {
            // LUKS1, or a header with no cost recorded: the KDF allocates
            // nothing worth sizing for, and the machine is what it always is.
            return requirement == nil ? engineFloorMiB : base
        }
        return base + requirement.kdfMiB + max(64, requirement.kdfMiB / 4)
    }

    /// The floor to hand the engine for this device, or nil to leave it alone.
    ///
    /// Nil for everything that is not a LUKS header and for a header that
    /// cannot be read, so a device this says nothing about is mounted exactly
    /// as it was before any of this existed. Both routes into a mount use this
    /// rather than composing it themselves: they differ in who may open the
    /// device, not in what the answer means.
    ///
    /// The bytes are already read at this size to identify the partition, so
    /// there is no extra pass over a disk anybody has to be allowed to open.
    public static func floor(forDevice devicePath: String, base: Int) -> Int? {
        guard let bytes = BootSector.read(devicePath: devicePath),
            let requirement = read(bytes)
        else { return nil }
        return ramMiB(for: requirement, base: base)
    }

    /// What the engine does when nobody tells it otherwise.
    ///
    /// Kept here so that "cannot read the header" lands exactly where it landed
    /// before any of this existed, rather than somewhere new.
    public static let engineFloorMiB = 2560
}
