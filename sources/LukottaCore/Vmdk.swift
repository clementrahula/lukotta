// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A VMDK descriptor, read far enough to decide whether it is safe to open.
///
/// A VMDK in its flat form always names another file. The descriptor is a short
/// text file listing extents, each naming the file that holds that slice of the
/// disk, and the engine opens every one of them. The descriptor is read whole
/// and capped at 2 MB, so the data cannot be stored within it.
///
/// The rule therefore cannot be that it names nothing else. It is that every
/// extent must be a plain file name situated beside the descriptor: nothing
/// absolute, nothing containing a separator, no `..`. That is what VMware
/// writes, and it prevents a descriptor from reaching elsewhere on the disk.
public struct VmdkDescriptor: Equatable, Sendable {
    public struct Extent: Equatable, Sendable {
        public let access: String
        public let sectors: UInt64
        public let type: String
        /// Absent for ZERO extents, which hold nothing and name nothing.
        public let filename: String?
    }

    public let createType: String?
    public let extents: [Extent]
    /// A differential image naming a parent. Not supported, and the parent
    /// would be a file elsewhere.
    public let hasDeltaLink: Bool

    /// The signature a sparse VMDK begins with, in place of the text
    /// descriptor. Such a file carries its descriptor within itself.
    public static let sparseMagic: [UInt8] = [0x4B, 0x44, 0x4D, 0x56]  // KDMV

    /// A name that points somewhere other than beside the descriptor.
    public static func reachesElsewhere(_ filename: String) -> Bool {
        filename.hasPrefix("/") || filename.contains("/") || filename.contains("\\")
            || filename == ".." || filename.isEmpty
    }

    public var namesAFileElsewhere: Bool {
        extents.contains { $0.filename.map(Self.reachesElsewhere) ?? false }
    }

    /// An extent that holds data but names no file.
    ///
    /// Every kind but ZERO lives in a file, and VMware always quotes its name.
    /// A line without one described part of a disk that is nowhere: it passed
    /// every objection, because a nil name reads as "names nothing elsewhere"
    /// and the every-extent-is-present loop skipped it, and the image was
    /// handed over with a hole in it.
    public var hasAnExtentWithNoFile: Bool {
        extents.contains { $0.type != "ZERO" && $0.filename == nil }
    }

    public static func parse(_ text: String) -> VmdkDescriptor {
        var createType: String?
        var extents: [Extent] = []
        var delta = false

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let head = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if ["RW", "RDONLY", "NOACCESS"].contains(head) {
                if let extent = parseExtent(line) { extents.append(extent) }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = unquoted(
                line[line.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces))
            switch key {
            case "createType": createType = value
            case "parentFileNameHint": delta = true
            default: continue
            }
        }
        return VmdkDescriptor(createType: createType, extents: extents, hasDeltaLink: delta)
    }

    /// `RW 655360 FLAT "disk-flat.vmdk" 0`, or `RW 4096 ZERO`.
    private static func parseExtent(_ line: String) -> Extent? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2, let sectors = UInt64(fields[1]) else { return nil }
        let access = fields[0]
        guard fields.count >= 3 else {
            return Extent(access: access, sectors: sectors, type: "", filename: nil)
        }
        let type = fields[2]
        if type == "ZERO" {
            return Extent(access: access, sectors: sectors, type: type, filename: nil)
        }
        // The name is quoted and may contain spaces, so it is taken from
        // between the quotes rather than from the whitespace split.
        let parts = line.components(separatedBy: "\"")
        let filename = parts.count >= 2 ? parts[1] : nil
        return Extent(access: access, sectors: sectors, type: type, filename: filename)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }
}

/// The header a sparse VMDK begins with, read far enough to locate the
/// descriptor within it.
///
/// A sparse VMDK holds the disk in grains, written wherever there was room and
/// located through a directory of tables. The text descriptor that a flat VMDK
/// keeps in a separate file is stored within this one, at an offset the header
/// gives.
///
/// The streamed form deflates every grain, which the engine's driver inflates
/// as it reads. It is identified here so that the two forms can be told apart
/// in tests and in a bug report, not in order to refuse it.
public struct SparseVmdkHeader: Equatable, Sendable {
    /// Where the descriptor begins, in sectors.
    public let descriptorOffset: UInt64
    /// How long it is, in sectors.
    public let descriptorSize: UInt64
    /// Whether every grain is deflated and preceded by a marker. That is the
    /// streamed form, which is what `ovftool` writes into an OVA.
    public let streamed: Bool

    /// The sector size the format is written in terms of.
    public static let sector: UInt64 = 512

    public static func parse(_ head: Data) -> SparseVmdkHeader? {
        guard head.count >= 80, Array(head.prefix(4)) == VmdkDescriptor.sparseMagic else {
            return nil
        }
        let flags = le32(head, 8)
        return SparseVmdkHeader(
            descriptorOffset: le64(head, 28),
            descriptorSize: le64(head, 36),
            streamed: flags & ((1 << 16) | (1 << 17)) != 0)
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 4)].reversed().reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
    }

    private static func le64(_ d: Data, _ at: Int) -> UInt64 {
        let i = d.index(d.startIndex, offsetBy: at)
        return d[i..<d.index(i, offsetBy: 8)].reversed().reduce(UInt64(0)) {
            $0 << 8 | UInt64($1)
        }
    }
}

extension DiskImage {
    /// The engine identifies a VMDK by its extension, so this does the same.
    public static func isVmdk(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vmdk"
    }

    /// Whether this VMDK is the streamed form, which is read and not written.
    ///
    /// The extension is the same for every form, so the header is what says
    /// so. A flat VMDK has no sparse header at all and is not this.
    public static func isStreamedVmdk(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 80) else { return false }
        return SparseVmdkHeader.parse(head)?.streamed ?? false
    }

    /// Whether this VMDK may be handed to the engine, or why not.
    public static func objection(toVmdk url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        // The descriptor is text and small. Anything larger than the engine
        // accepts is not a descriptor.
        guard let head = try? handle.read(upToCount: 2 * 1024 * 1024), !head.isEmpty else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        // A sparse VMDK is the disk itself rather than a text file describing
        // one, so its descriptor is read from within it.
        var text = head
        if Array(head.prefix(4)) == VmdkDescriptor.sparseMagic {
            guard let sparse = SparseVmdkHeader.parse(head) else {
                return appString(
                    "“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
            }
            guard EnginePaths.opensSparseVmdk else {
                return appString(
                    "“\(url.lastPathComponent)” is a sparse VMDK, which this build of the drive engine cannot open. A flat one, or a raw image, would work."
                )
            }
            let at = sparse.descriptorOffset * SparseVmdkHeader.sector
            let length = sparse.descriptorSize * SparseVmdkHeader.sector
            guard at > 0, length > 0, length <= 2 * 1024 * 1024,
                (try? handle.seek(toOffset: at)) != nil,
                let inside = try? handle.read(upToCount: Int(length)), !inside.isEmpty
            else {
                return appString(
                    "“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
            }
            // Padded to whole sectors with zero bytes, which are not content.
            text = inside.prefix(while: { $0 != 0 })
        }
        let descriptor = VmdkDescriptor.parse(String(decoding: text, as: UTF8.self))
        if descriptor.hasDeltaLink {
            return appString(
                "“\(url.lastPathComponent)” is part of a chain of snapshots, which \(appName) cannot open. Open the disk it was made from."
            )
        }
        guard !descriptor.extents.isEmpty else {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }
        if descriptor.hasAnExtentWithNoFile {
            return appString("“\(url.lastPathComponent)” is not a disk image \(appName) can read.")
        }
        if descriptor.namesAFileElsewhere {
            return appString(
                "“\(url.lastPathComponent)” refers to another file on this Mac, which would be opened along with it. \(appName) does not open images that name other files."
            )
        }
        // Every extent must be present. Otherwise the engine opens those it
        // finds and serves a disk with gaps in it.
        let directory = url.deletingLastPathComponent()
        for extent in descriptor.extents {
            guard let name = extent.filename else { continue }
            let beside = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: beside.path) {
                return appString(
                    "“\(url.lastPathComponent)” needs “\(name)”, which is not beside it. A disk image of this kind is a set of files, and every one is required."
                )
            }
            // A name with no path in it can still be a link to somewhere else.
            // The point of refusing paths is that opening this image opens only
            // what is beside it, and a link that leaves the directory defeats
            // that as surely as a path would have.
            let real = beside.resolvingSymlinksInPath().standardizedFileURL
            if real.deletingLastPathComponent().standardizedFileURL
                != directory.resolvingSymlinksInPath().standardizedFileURL
            {
                return appString(
                    "“\(url.lastPathComponent)” refers to another file on this Mac, which would be opened along with it. \(appName) does not open images that name other files."
                )
            }
        }
        return nil
    }
}
