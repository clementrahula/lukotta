import Foundation

/// A VMDK descriptor, read far enough to decide whether it is safe to open.
///
/// Unlike a qcow2, a VMDK **always** names another file. Its descriptor is a
/// short text file listing extents, each pointing at the file holding that
/// slice of the disk, and the engine opens every one of them. There is no
/// self-contained form: the descriptor is read whole and capped at 2 MB, so the
/// data cannot live in it.
///
/// So the rule cannot be "names nothing else". It is that every extent must be
/// a plain file name sitting beside the descriptor — no directory separators,
/// no `..`, nothing absolute. That is exactly what a VMware-written VMDK looks
/// like, and it stops a descriptor from reaching anywhere else on the disk.
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
    /// A differential image pointing at a parent. Not supported, and it would
    /// name a file elsewhere.
    public let hasDeltaLink: Bool

    /// The signature a sparse VMDK starts with, in place of the text
    /// descriptor. That form is not supported by the engine's image layer.
    public static let sparseMagic: [UInt8] = [0x4B, 0x44, 0x4D, 0x56]  // KDMV

    /// A name that points somewhere other than beside the descriptor.
    public static func reachesElsewhere(_ filename: String) -> Bool {
        filename.hasPrefix("/") || filename.contains("/") || filename.contains("\\")
            || filename == ".." || filename.isEmpty
    }

    public var namesAFileElsewhere: Bool {
        extents.contains { $0.filename.map(Self.reachesElsewhere) ?? false }
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
        // The name is quoted and may hold spaces, so it is taken from the
        // quotes rather than from the split.
        let parts = line.components(separatedBy: "\"")
        let filename = parts.count >= 2 ? parts[1] : nil
        return Extent(access: access, sectors: sectors, type: type, filename: filename)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }
}

extension DiskImage {
    /// The engine decides a VMDK by its name, so this does too.
    public static func isVmdk(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vmdk"
    }

    /// Whether this VMDK may be handed to the engine, or why not.
    public static func objection(toVmdk url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        defer { try? handle.close() }
        // The descriptor is text and small. Anything larger than the engine
        // itself accepts is not one.
        guard let head = try? handle.read(upToCount: 2 * 1024 * 1024), !head.isEmpty else {
            return appString("“\(url.lastPathComponent)” could not be read.")
        }
        if Array(head.prefix(4)) == VmdkDescriptor.sparseMagic {
            return appString(
                "“\(url.lastPathComponent)” is a sparse VMDK, which \(appName) cannot open. A flat one, or a raw image, would work."
            )
        }
        let descriptor = VmdkDescriptor.parse(String(decoding: head, as: UTF8.self))
        if descriptor.hasDeltaLink {
            return appString(
                "“\(url.lastPathComponent)” is part of a chain of snapshots, which \(appName) cannot open. Open the disk it was made from."
            )
        }
        guard !descriptor.extents.isEmpty else {
            return appString("“\(url.lastPathComponent)” is not a disk image this app can read.")
        }
        if descriptor.namesAFileElsewhere {
            return appString(
                "“\(url.lastPathComponent)” refers to another file on this Mac, which would be opened along with it. \(appName) does not open images that name other files."
            )
        }
        // Every extent has to actually be there, or the engine opens what it
        // can and serves a disk with holes in it.
        let directory = url.deletingLastPathComponent()
        for extent in descriptor.extents {
            guard let name = extent.filename else { continue }
            let beside = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: beside.path) {
                return appString(
                    "“\(url.lastPathComponent)” needs “\(name)”, which is not beside it. Disk images of this kind come as a set of files, and all of them are needed."
                )
            }
        }
        return nil
    }
}
