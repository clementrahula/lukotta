// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Changing an attribute inside a record.
///
/// A record is attributes laid end to end, each saying how long it is, ending
/// with a marker. Making one longer or shorter means moving every attribute
/// after it and writing down four numbers that have to agree: the attribute's
/// own length, its value's length, where its value starts, and how much of the
/// record is used.
///
/// **A record where those disagree is not a broken record, it is a different
/// record.** A reader walks it by adding lengths, so a length that is wrong by
/// eight makes the next attribute start eight bytes into the last one -- and
/// whatever is there is read as a type, a length, and a value. There is no
/// error; there is a file with attributes nobody wrote.
///
/// So this is one pass: take the attributes apart, put the new one in its
/// place, and lay them out again. Nothing is patched in place, because patching
/// is where two numbers get the chance to disagree.
public enum NTFSRecordEdit {

    /// Replace one attribute's value, growing or shrinking the record to suit.
    ///
    /// - Parameters:
    ///   - kind: which attribute. The first of that kind, which is what every
    ///     caller here wants -- a record with two `$DATA` attributes has named
    ///     streams, and those are not edited by this.
    ///   - name: the attribute's own name, for the ones that have one. A
    ///     directory has three called `$I30` and they are told apart by type,
    ///     but a record can hold several of a type with different names.
    ///   - value: the new bytes.
    /// - Returns: nil when it will not fit, or when the record does not parse.
    ///   Not fitting is a real answer: the attribute has to go out to the disk
    ///   instead, or the record needs an `$ATTRIBUTE_LIST`, and both are the
    ///   caller's decision.
    public static func replacing(
        _ kind: NTFSAttribute.Kind, named name: String?, with value: Data, in record: Data,
        header: NTFSRecord.Header
    ) -> Data? {
        guard let pieces = attributes(of: record, header: header) else { return nil }
        var replaced = false
        var out: [Piece] = []
        for piece in pieces {
            if !replaced, piece.kind == kind.rawValue, piece.name == name, piece.isResident {
                out.append(
                    Piece(
                        kind: piece.kind, name: piece.name, isResident: true, id: piece.id,
                        indexed: piece.indexed, value: value, whole: nil))
                replaced = true
            } else {
                out.append(piece)
            }
        }
        guard replaced else { return nil }
        return lay(out, into: record, header: header)
    }

    /// Replace the whole of an attribute, header and all.
    ///
    /// For the non-resident ones, where what changes is the runlist and the
    /// sizes rather than a value: those live in the attribute's header, so the
    /// caller builds the bytes and this puts them back in order.
    public static func replacingWhole(
        _ kind: NTFSAttribute.Kind, named name: String?, with bytes: Data, in record: Data,
        header: NTFSRecord.Header
    ) -> Data? {
        guard let pieces = attributes(of: record, header: header) else { return nil }
        var replaced = false
        var out: [Piece] = []
        for piece in pieces {
            if !replaced, piece.kind == kind.rawValue, piece.name == name {
                out.append(
                    Piece(
                        kind: piece.kind, name: piece.name, isResident: piece.isResident,
                        id: piece.id, indexed: piece.indexed, value: Data(), whole: bytes))
                replaced = true
            } else {
                out.append(piece)
            }
        }
        guard replaced else { return nil }
        return lay(out, into: record, header: header)
    }

    /// Put an attribute into a record that has not got one.
    ///
    /// Attributes are kept in ascending order of type, and NTFS relies on it: a
    /// reader looking for one stops when it passes the type. So the new one
    /// goes where its number puts it, not on the end.
    ///
    /// - Returns: nil when the record already has that attribute with that
    ///   name, or when it will not fit. A second attribute of the same name is
    ///   not an addition, it is a record with two answers to one question.
    public static func adding(
        _ bytes: Data, type: UInt32, named name: String?, to record: Data,
        header: NTFSRecord.Header
    ) -> Data? {
        guard let pieces = attributes(of: record, header: header) else { return nil }
        guard !pieces.contains(where: { $0.kind == type && $0.name == name }) else { return nil }
        let piece = Piece(
            kind: type, name: name, isResident: false, id: 0, indexed: 0, value: Data(),
            whole: bytes)
        var out: [Piece] = []
        var placed = false
        for existing in pieces {
            if !placed, existing.kind > type {
                out.append(piece)
                placed = true
            }
            out.append(existing)
        }
        if !placed { out.append(piece) }
        return lay(out, into: record, header: header)
    }

    /// One attribute, taken apart.
    struct Piece {
        let kind: UInt32
        let name: String?
        let isResident: Bool
        let id: UInt16
        let indexed: UInt8
        /// For a resident attribute being rebuilt: its value.
        let value: Data
        /// For anything kept as it was, or replaced whole: its bytes.
        let whole: Data?
    }

    /// Walk a record's attributes.
    static func attributes(of record: Data, header: NTFSRecord.Header) -> [Piece]? {
        var pieces: [Piece] = []
        var at = header.firstAttributeOffset
        let base = record.startIndex
        var seen = 0
        while at + 8 <= header.usedLength, seen < 64 {
            seen += 1
            let kind = read32(record, at)
            if kind == 0xFFFF_FFFF { return pieces }
            let length = Int(read32(record, at + 4))
            guard length >= 24, at + length <= header.usedLength, at + length <= record.count
            else { return nil }

            let nameLength = Int(record[base + at + 9])
            let nameOffset = Int(read16(record, at + 10))
            var name: String?
            if nameLength > 0, at + nameOffset + nameLength * 2 <= record.count {
                var units: [UInt16] = []
                for index in 0..<nameLength {
                    let unit = base + at + nameOffset + index * 2
                    units.append(UInt16(record[unit]) | (UInt16(record[unit + 1]) << 8))
                }
                name = String(decoding: units, as: UTF16.self)
            }

            let isResident = record[base + at + 8] == 0
            var value = Data()
            if isResident {
                let valueOffset = Int(read16(record, at + 0x14))
                let valueLength = Int(read32(record, at + 0x10))
                guard at + valueOffset + valueLength <= record.count else { return nil }
                value =
                    record[
                        (base + at + valueOffset)..<(base + at + valueOffset + valueLength)]
            }
            pieces.append(
                Piece(
                    kind: kind, name: name, isResident: isResident,
                    id: read16(record, at + 0x0E), indexed: record[base + at + 0x16],
                    value: Data(value),
                    whole: Data(record[(base + at)..<(base + at + length)])))
            at += length
        }
        return nil
    }

    /// Lay attributes back into a record.
    static func lay(_ pieces: [Piece], into record: Data, header: NTFSRecord.Header) -> Data? {
        var laid: [UInt8] = []
        for piece in pieces {
            if let whole = piece.whole {
                laid.append(contentsOf: [UInt8](whole))
                continue
            }
            guard let bytes = resident(piece) else { return nil }
            laid.append(contentsOf: bytes)
        }
        let used = header.firstAttributeOffset + laid.count + 8
        guard used <= header.allocatedLength else { return nil }

        var out = [UInt8](record)
        // Everything from the first attribute to the end of the slot is
        // rewritten, so nothing of the old layout is left where a reader could
        // reach it.
        for index in header.firstAttributeOffset..<header.allocatedLength { out[index] = 0 }
        out.replaceSubrange(
            header.firstAttributeOffset..<(header.firstAttributeOffset + laid.count), with: laid)
        write32(&out, header.firstAttributeOffset + laid.count, 0xFFFF_FFFF)
        write32(&out, 0x18, UInt32(used))
        return Data(out)
    }

    /// Build a resident attribute's bytes from its parts.
    static func resident(_ piece: Piece) -> [UInt8]? {
        let units = piece.name.map { Array($0.utf16) } ?? []
        let nameOffset = 24
        let valueOffset = (nameOffset + units.count * 2 + 7) & ~7
        let length = (valueOffset + piece.value.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        write32(&bytes, 0x00, piece.kind)
        write32(&bytes, 0x04, UInt32(length))
        bytes[0x08] = 0
        bytes[0x09] = UInt8(units.count)
        write16(&bytes, 0x0A, UInt16(units.isEmpty ? 0 : nameOffset))
        write16(&bytes, 0x0C, 0)
        write16(&bytes, 0x0E, piece.id)
        write32(&bytes, 0x10, UInt32(piece.value.count))
        write16(&bytes, 0x14, UInt16(valueOffset))
        bytes[0x16] = piece.indexed
        for (index, unit) in units.enumerated() {
            write16(&bytes, nameOffset + index * 2, unit)
        }
        bytes.replaceSubrange(valueOffset..<valueOffset + piece.value.count, with: piece.value)
        return bytes
    }

    // MARK: - Arithmetic

    static func read16(_ bytes: Data, _ at: Int) -> UInt16 {
        let base = bytes.startIndex + at
        guard base + 1 < bytes.endIndex else { return 0 }
        return UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8)
    }
    static func read32(_ bytes: Data, _ at: Int) -> UInt32 {
        UInt32(read16(bytes, at)) | (UInt32(read16(bytes, at + 2)) << 16)
    }
    static func write16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt16) {
        bytes[at] = UInt8(value & 0xFF)
        bytes[at + 1] = UInt8(value >> 8)
    }
    static func write32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
}
