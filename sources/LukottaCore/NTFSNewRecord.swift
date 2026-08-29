// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Building the record that *is* a new file.
///
/// On NTFS a file is not a name in a directory with data somewhere else. It is
/// a record in the master file table holding a set of attributes, and the
/// directory entry is a second copy of some of that. So creating a file means
/// laying out a record: its header, `$STANDARD_INFORMATION` with the times and
/// the DOS flags, `$FILE_NAME` with the name and the parent, `$DATA` with the
/// contents, and an end marker.
///
/// **Everything here is arithmetic on a byte buffer, and every offset is one a
/// reader will believe.** A length that disagrees with what follows it does not
/// fail; it makes the next reader walk into the middle of an attribute and read
/// whatever is there as a type. So the layout is built in one pass, the lengths
/// are computed from what was actually written, and nothing is asserted twice.
///
/// The record is returned with the fixup *not* applied -- the bytes are as a
/// reader would hold them, and `NTFSRecordWrite.onDisk` turns them into what
/// goes down. That keeps the one place that knows about signatures the one
/// place that knows about signatures.
public enum NTFSNewRecord {

    /// Attributes go in ascending order of type, and NTFS relies on it: a
    /// reader looking for `$DATA` stops when it passes 0x80.
    public static let standardInformation: UInt32 = 0x10
    public static let fileName: UInt32 = 0x30
    public static let data: UInt32 = 0x80
    public static let indexRoot: UInt32 = 0x90

    /// The DOS attribute bit that says a name is a directory.
    ///
    /// It goes in `$STANDARD_INFORMATION`, in `$FILE_NAME`, and in the parent's
    /// index entry, and the record header carries its own flag as well. A
    /// directory that says so in three places out of four is one Finder shows
    /// as a file and Windows shows as a directory.
    public static let endMarker: UInt32 = 0xFFFF_FFFF
    public static let directoryFlag: UInt32 = 0x1000_0000

    /// What a directory's index is called and how it is arranged.
    public static let indexName = "$I30"
    /// Names are compared case-insensitively through `$UpCase`. Rule 1.
    public static let fileNameCollation: UInt32 = 1

    /// Where the fixup array starts, on the volumes this reads.
    ///
    /// Records that carry their own number keep it at 0x2C and start the array
    /// at 0x30. The ones on this volume start it at 0x2A and have no such
    /// field, which is the older layout and still current -- both are read by
    /// following `fixupOffset`, which is why a reader never has to know.
    public static let fixupOffset = 42

    /// What a file needs to exist.
    public struct Plan: Sendable {
        public let record: UInt64
        /// Bumped every time a record is reused, so a stale reference to the
        /// file that used to live here is recognised as stale rather than
        /// followed to a different file.
        public let sequence: UInt16
        public let parent: UInt64
        public let parentSequence: UInt16
        public let name: String
        public let namespace: NTFSFileName.Namespace
        public let times: NTFSTimestamps.Times
        /// The DOS attribute bits. 0x20 is ARCHIVE, which is what a newly
        /// written file carries.
        public let dosFlags: UInt32
        /// Which entry of `$Secure` says who may open this. Copied from the
        /// parent by every implementation that writes NTFS; inventing one would
        /// be inventing permissions.
        public let securityID: UInt32
        /// The file's bytes, held inside the record.
        public let contents: Data
        /// Whether this is a directory. A directory carries an empty index
        /// instead of contents, and says so in its flags.
        public let isDirectory: Bool

        public init(
            record: UInt64, sequence: UInt16, parent: UInt64, parentSequence: UInt16,
            name: String, namespace: NTFSFileName.Namespace, times: NTFSTimestamps.Times,
            dosFlags: UInt32 = 0x20, securityID: UInt32, contents: Data = Data(),
            isDirectory: Bool = false
        ) {
            self.isDirectory = isDirectory
            self.record = record
            self.sequence = sequence
            self.parent = parent
            self.parentSequence = parentSequence
            self.name = name
            self.namespace = namespace
            self.times = times
            self.dosFlags = dosFlags
            self.securityID = securityID
            self.contents = contents
        }
    }

    /// Lay out the record.
    ///
    /// - Returns: nil when it will not fit, or when the plan is not one a file
    ///   can be made from. A record that does not fit is a file whose data must
    ///   go out to clusters instead, which is the caller's decision and not
    ///   something to make silently by truncating.
    public static func compose(_ plan: Plan, recordSize: Int, sectorSize: Int) -> Data? {
        guard recordSize >= 512, sectorSize > 2, recordSize % sectorSize == 0 else { return nil }
        let units = Array(plan.name.utf16)
        guard !units.isEmpty, units.count <= 255 else { return nil }
        guard plan.contents.count <= recordSize else { return nil }

        // One entry for the signature, then one per sector.
        let fixupCount = recordSize / sectorSize + 1
        let firstAttribute = align(fixupOffset + fixupCount * 2)
        guard firstAttribute < recordSize else { return nil }

        var bytes = [UInt8](repeating: 0, count: recordSize)
        var at = firstAttribute

        guard
            let information = resident(
                type: standardInformation, value: standardInformationValue(plan), id: 0),
            let name = resident(
                type: fileName, value: fileNameValue(plan, units: units), id: 1, indexed: true)
        else { return nil }
        // A directory carries an empty index where a file carries its bytes.
        let third: [UInt8]?
        if plan.isDirectory {
            third = resident(
                type: indexRoot, value: emptyIndexValue(blockSize: 4096, bytesPerCluster: 4096),
                id: 2, name: indexName)
        } else {
            third = resident(type: data, value: plan.contents, id: 2)
        }
        guard let contents = third else { return nil }

        // Ascending order of type, which is not a convention but a rule: a
        // reader looking for $DATA stops when it passes 0x80.
        for attribute in [information, name, contents] {
            guard at + attribute.count <= recordSize - 8 else { return nil }
            bytes.replaceSubrange(at..<at + attribute.count, with: attribute)
            at += attribute.count
        }
        // The end marker, and the four bytes after it that every writer leaves.
        guard at + 8 <= recordSize else { return nil }
        write32(&bytes, at, endMarker)
        at += 8

        // The header, last, because it says how long everything before it came
        // to. Working that out beforehand means two answers that can disagree.
        bytes.replaceSubrange(0..<4, with: NTFSRecord.signature)
        write16(&bytes, 0x04, UInt16(fixupOffset))
        write16(&bytes, 0x06, UInt16(fixupCount))
        write16(&bytes, 0x10, plan.sequence)
        write16(&bytes, 0x12, 1)  // one name, so one link
        write16(&bytes, 0x14, UInt16(firstAttribute))
        write16(&bytes, 0x16, plan.isDirectory ? 0x0003 : 0x0001)
        write32(&bytes, 0x18, UInt32(at))
        write32(&bytes, 0x1C, UInt32(recordSize))
        write16(&bytes, 0x28, 3)  // the next attribute id to hand out
        // The fixup array's first entry is the signature. It is set when the
        // record is written, not here: the value belongs to the volume's
        // sequence, and a record composed twice must not claim to have been
        // written twice.
        return Data(bytes)
    }

    // MARK: - The attributes

    /// `$STANDARD_INFORMATION`: when, and what kind of file.
    public static func standardInformationValue(_ plan: Plan) -> Data {
        var value = [UInt8](repeating: 0, count: 72)
        writeTimes(&value, 0, plan.times)
        write32(&value, 32, plan.dosFlags | (plan.isDirectory ? directoryFlag : 0))
        // 36 maximum versions, 40 version number, 44 class id: all zero, and
        // all unused by anything that reads NTFS today.
        write32(&value, 52, plan.securityID)
        // 56 quota charged, 64 update sequence number: zero. A volume with
        // quotas turned on has $Quota to keep them in, and writing a charge
        // here without updating that would be a number nothing agrees with.
        return Data(value)
    }

    /// `$FILE_NAME`: the name, the parent, and a copy of the times.
    ///
    /// The times and sizes appear here as well as in
    /// `$STANDARD_INFORMATION` because a directory listing reads them straight
    /// out of the index without opening any record. They are a cache, and like
    /// any cache they can go stale -- which is why a reader that wants the
    /// truth asks the record.
    public static func fileNameValue(_ plan: Plan, units: [UInt16]) -> Data {
        var value = [UInt8](repeating: 0, count: 66 + units.count * 2)
        write64(&value, 0, reference(plan.parent, sequence: plan.parentSequence))
        writeTimes(&value, 8, plan.times)
        // Allocated and real size. Both zero for a file whose bytes live inside
        // its record: nothing is allocated on the disk, and a listing that
        // showed a size here would be showing one the record disagrees with.
        write64(&value, 40, 0)
        write64(&value, 48, UInt64(plan.contents.count))
        write32(&value, 56, plan.dosFlags | (plan.isDirectory ? directoryFlag : 0))
        write32(&value, 60, 0)  // no reparse point and no extended attributes
        value[64] = UInt8(units.count)
        value[65] = plan.namespace.rawValue
        for (index, unit) in units.enumerated() {
            write16(&value, 66 + index * 2, unit)
        }
        return Data(value)
    }

    /// A resident attribute: its header, its value, and padding to eight.
    static func resident(
        type: UInt32, value: Data, id: UInt16, indexed: Bool = false, name: String? = nil
    ) -> [UInt8]? {
        let nameUnits = name.map { Array($0.utf16) } ?? []
        let nameAt = 24
        let valueAt = align(nameAt + nameUnits.count * 2)
        let length = align(valueAt + value.count)
        guard length <= 0xFFFF, nameUnits.count <= 255 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        write32(&bytes, 0x00, type)
        write32(&bytes, 0x04, UInt32(length))
        bytes[0x08] = 0  // resident
        bytes[0x09] = UInt8(nameUnits.count)
        write16(&bytes, 0x0A, UInt16(nameUnits.isEmpty ? 0 : nameAt))
        write16(&bytes, 0x0C, 0)  // not compressed, encrypted or sparse
        write16(&bytes, 0x0E, id)
        write32(&bytes, 0x10, UInt32(value.count))
        write16(&bytes, 0x14, UInt16(valueAt))
        // Set on $FILE_NAME, and it means the attribute is also kept in an
        // index. Windows sets it; a record without it is one chkdsk repairs.
        bytes[0x16] = indexed ? 1 : 0
        for (index, unit) in nameUnits.enumerated() {
            write16(&bytes, nameAt + index * 2, unit)
        }
        bytes.replaceSubrange(valueAt..<valueAt + value.count, with: value)
        return bytes
    }

    /// An `$INDEX_ROOT` holding nothing: a directory with no names in it yet.
    ///
    /// Sixteen bytes saying what the index is over and how it is compared, a
    /// node header, and an end marker. Every directory begins as this, and
    /// grows a `$BITMAP` and an `$INDEX_ALLOCATION` only when it needs blocks.
    public static func emptyIndexValue(blockSize: Int, bytesPerCluster: Int) -> Data {
        var value = [UInt8](repeating: 0, count: 16 + 16 + 16)
        write32(&value, 0x00, fileName)  // the index is over $FILE_NAME
        write32(&value, 0x04, fileNameCollation)
        write32(&value, 0x08, UInt32(blockSize))
        // Clusters per index block. NTFS writes the count when a block is at
        // least a cluster, and a negative log when it is smaller.
        value[0x0C] =
            blockSize >= bytesPerCluster
            ? UInt8(max(blockSize / max(bytesPerCluster, 1), 1))
            : UInt8(bitPattern: Int8(-3))

        // The node: entries begin straight after its own header, and there is
        // one -- the marker that says the node ends here.
        write32(&value, 0x10, 16)  // first entry, from the node header
        write32(&value, 0x14, 32)  // and the entries end after the marker
        write32(&value, 0x18, 32)  // with no room to spare: this is a record
        write32(&value, 0x1C, 0)  // nothing below it

        write32(&value, 0x20 + 8, 16)  // the marker's length
        write16(&value, 0x20 + 12, 0x0002)  // and its flag: the end
        return Data(value)
    }

    // MARK: - Arithmetic

    /// Attributes begin on eight-byte boundaries, without exception.
    static func align(_ value: Int) -> Int { (value + 7) & ~7 }

    /// A reference is a record number and the sequence it had when the
    /// reference was made. The sequence is what makes a stale reference
    /// detectable instead of pointing at whatever file took the record next.
    public static func reference(_ record: UInt64, sequence: UInt16) -> UInt64 {
        (record & 0x0000_FFFF_FFFF_FFFF) | (UInt64(sequence) << 48)
    }

    static func writeTimes(_ bytes: inout [UInt8], _ at: Int, _ times: NTFSTimestamps.Times) {
        write64(&bytes, at, ticks(times.created))
        write64(&bytes, at + 8, ticks(times.modified))
        write64(&bytes, at + 16, ticks(times.recordChanged))
        write64(&bytes, at + 24, ticks(times.accessed))
    }

    /// Hundred-nanosecond ticks since 1601, which is how NTFS counts.
    public static func ticks(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970 + Double(NTFSTimestamps.epochDifference)
        guard seconds > 0 else { return 0 }
        let scaled = seconds * Double(NTFSTimestamps.ticksPerSecond)
        guard scaled < Double(UInt64.max) else { return 0 }
        return UInt64(scaled)
    }

    static func write16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt16) {
        bytes[at] = UInt8(value & 0xFF)
        bytes[at + 1] = UInt8(value >> 8)
    }
    static func write32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
    static func write64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
}
