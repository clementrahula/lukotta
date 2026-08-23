// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Reading fixed-width fields out of a disk image's header.
///
/// Every format here is a header of numbers at known offsets, and each of the
/// five parsers had grown its own copy of these. They are stated once so a
/// parser reads as the format it describes and nothing else.
///
/// Nothing is checked here. The caller has already established that the field
/// lies inside the data it holds, which is the check that matters and which
/// belongs where the offsets are known.
extension Data {
    /// Big-endian, as VHD and qcow2 write their fields.
    func be32(at offset: Int) -> UInt32 { number(at: offset, bytes: 4) }
    func be64(at offset: Int) -> UInt64 { number(at: offset, bytes: 8) }

    /// Little-endian, as VDI, VMDK and VHDX write theirs.
    func le16(at offset: Int) -> UInt16 { number(at: offset, bytes: 2, littleEndian: true) }
    func le32(at offset: Int) -> UInt32 { number(at: offset, bytes: 4, littleEndian: true) }
    func le64(at offset: Int) -> UInt64 { number(at: offset, bytes: 8, littleEndian: true) }

    private func number<T: FixedWidthInteger>(
        at offset: Int, bytes: Int, littleEndian: Bool = false
    ) -> T {
        let start = index(startIndex, offsetBy: offset)
        let field = self[start..<index(start, offsetBy: bytes)]
        // Indices are not assumed to start at zero: a slice of a file carries
        // its parent's indices, and these are called on slices.
        return (littleEndian ? AnySequence(field.reversed()) : AnySequence(field))
            .reduce(T(0)) { $0 << 8 | T($1) }
    }
}
