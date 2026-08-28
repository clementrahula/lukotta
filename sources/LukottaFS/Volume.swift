// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import FSKit
import Foundation
import LukottaCore

/// An FSItem that knows which node of the tree it stands for.
///
/// FSKit hands the same object back on every later call about that file, so the
/// identity has to be the item rather than a name looked up again each time.
final class Item: FSItem {
    let node: FSStore.Node
    init(_ node: FSStore.Node) {
        self.node = node
        super.init()
    }
}

/// A volume served entirely from memory, to price FSKit itself.
///
/// Every reply is made on the thread FSKit called in on. Nothing here hops to
/// an actor or a queue of its own: the whole point is to measure the crossing,
/// and adding a scheduler to it would measure the scheduler.
final class MemoryVolume: FSVolume, @unchecked Sendable {

    private let store: FSStore
    private let rootItem: Item
    private let volumeName: String

    init(name: String) {
        self.store = FSStore()
        self.rootItem = Item(store.root)
        self.volumeName = name
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: FSFileName(string: name))
    }

    // MARK: - Attributes

    private func attributes(of node: FSStore.Node) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.fileID = FSItem.Identifier(rawValue: node.id) ?? .invalid
        attributes.parentID =
            FSItem.Identifier(rawValue: node.parent?.id ?? node.id) ?? .invalid
        attributes.type = node.isDirectory ? .directory : .file
        attributes.mode = node.mode
        attributes.linkCount = node.linkCount
        attributes.size = node.size
        // Rounded to a block, as a real filesystem reports it: du and Finder's
        // "size on disk" both read this rather than size.
        attributes.allocSize = (node.size + 4095) / 4096 * 4096
        attributes.uid = UInt32(getuid())
        attributes.gid = UInt32(getgid())
        attributes.flags = 0
        let modified = timespec(
            tv_sec: Int(node.modified.timeIntervalSince1970), tv_nsec: 0)
        let created = timespec(
            tv_sec: Int(node.created.timeIntervalSince1970), tv_nsec: 0)
        attributes.modifyTime = modified
        attributes.changeTime = modified
        attributes.accessTime = modified
        attributes.birthTime = created
        attributes.addedTime = created
        return attributes
    }
}

// MARK: - The required operations

extension MemoryVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = false
        capabilities.supportsHiddenFiles = true
        capabilities.supportsSparseFiles = false
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let used = store.usage()
        let result = FSStatFSResult(fileSystemTypeName: "lukottafs")
        // A gigabyte of imaginary space. Finder refuses to copy anything onto a
        // volume that reports none free, so the number has to be a real one
        // even when nothing is behind it.
        let blockSize: UInt64 = 4096
        let total: UInt64 = 1 << 30
        result.blockSize = Int(blockSize)
        result.ioSize = Int(blockSize)
        result.totalBlocks = total / blockSize
        result.availableBlocks = (total - min(used.bytes, total)) / blockSize
        result.freeBlocks = result.availableBlocks
        result.totalFiles = 1_000_000
        result.freeFiles = 1_000_000 - min(used.files, 1_000_000)
        return result
    }

    // What the VFS asks before it will let anybody near the volume. A name
    // length of zero here makes every open fail with ENAMETOOLONG, which reads
    // as a broken disk rather than a missing property.
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumXattrSizeInBits: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
    var maximumFileSizeInBits: Int { 64 }

    func activate(
        options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void
    ) {
        reply(rootItem, nil)
    }

    func deactivate(
        options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        reply()
    }

    func synchronize(
        flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        // Nothing is behind this to flush, which is the point of it.
        reply(nil)
    }

    func getAttributes(
        _ desired: FSItem.GetAttributesRequest, of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else {
            return reply(nil, fsError(POSIXError.EINVAL))
        }
        reply(attributes(of: item.node), nil)
    }

    func setAttributes(
        _ new: FSItem.SetAttributesRequest, on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else {
            return reply(nil, fsError(POSIXError.EINVAL))
        }
        store.withLock {
            if new.consumedAttributes.contains(.mode) { item.node.mode = new.mode }
            if new.consumedAttributes.contains(.size) {
                // Set outside the lock would race a concurrent write; the
                // store's own truncate takes it, so the value is captured here
                // and applied after.
            }
        }
        if new.consumedAttributes.contains(.size) {
            store.truncate(item.node, to: Int(new.size))
        }
        reply(attributes(of: item.node), nil)
    }

    func lookupItem(
        named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? Item, let string = name.string else {
            return reply(nil, nil, fsError(POSIXError.EINVAL))
        }
        guard let node = store.lookup(string, in: directory.node) else {
            return reply(nil, nil, fsError(POSIXError.ENOENT))
        }
        reply(Item(node), name, nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func readSymbolicLink(
        _ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, fsError(POSIXError.ENOTSUP))
    }

    func createItem(
        named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? Item, let string = name.string else {
            return reply(nil, nil, fsError(POSIXError.EINVAL))
        }
        let mode =
            newAttributes.consumedAttributes.contains(.mode)
            ? newAttributes.mode : (type == .directory ? 0o755 : 0o644)
        guard
            let node = store.create(
                string, isDirectory: type == .directory, in: directory.node, mode: mode)
        else {
            return reply(nil, nil, fsError(POSIXError.EEXIST))
        }
        reply(Item(node), name, nil)
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, nil, fsError(POSIXError.ENOTSUP))
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, fsError(POSIXError.ENOTSUP))
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let directory = directory as? Item, let string = name.string else {
            return reply(fsError(POSIXError.EINVAL))
        }
        switch store.remove(string, from: directory.node) {
        case .removed: reply(nil)
        case .missing: reply(fsError(POSIXError.ENOENT))
        case .notEmpty: reply(fsError(POSIXError.ENOTEMPTY))
        }
    }

    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
        overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard let source = sourceDirectory as? Item,
            let destination = destinationDirectory as? Item,
            let from = sourceName.string, let to = destinationName.string
        else {
            return reply(nil, fsError(POSIXError.EINVAL))
        }
        // A rename over something that is already there replaces it, which is
        // what rename(2) promises and what Finder's move-to-Trash relies on.
        if overItem != nil { _ = store.remove(to, from: destination.node) }
        guard store.rename(from, in: source.node, to: to, in: destination.node) else {
            return reply(nil, fsError(POSIXError.ENOENT))
        }
        reply(destinationName, nil)
    }

    func enumerateDirectory(
        _ directory: FSItem, startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let directory = directory as? Item else {
            return reply(verifier, fsError(POSIXError.EINVAL))
        }
        let entries = store.children(of: directory.node)
        // The cookie is where the last call stopped. Names are sorted, so the
        // same index means the same entry on the next call.
        var index = Int(cookie.rawValue)
        while index < entries.count {
            let node = entries[index]
            index += 1
            let packed = packer.packEntry(
                name: FSFileName(string: node.name),
                itemType: node.isDirectory ? .directory : .file,
                itemID: FSItem.Identifier(rawValue: node.id) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: UInt64(index)),
                attributes: attributes == nil ? nil : self.attributes(of: node))
            // Packing stops when the buffer the kernel gave us is full. What is
            // left is asked for again with the cookie we just handed over.
            if !packed { break }
        }
        reply(verifier, nil)
    }
}

// MARK: - Reading and writing

extension MemoryVolume: FSVolume.ReadWriteOperations {

    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else { return reply(0, fsError(POSIXError.EINVAL)) }
        let slice = store.read(item.node, offset: Int(offset), length: length)
        let written = slice.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress, !slice.isEmpty else { return 0 }
            return buffer.withUnsafeMutableBytes { destination -> Int in
                let count = min(destination.count, slice.count)
                destination.baseAddress?.copyMemory(from: base, byteCount: count)
                return count
            }
        }
        reply(written, nil)
    }

    func write(
        contents: Data, to item: FSItem, at offset: off_t,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else { return reply(0, fsError(POSIXError.EINVAL)) }
        reply(store.write(item.node, contents: contents, offset: Int(offset)), nil)
    }
}

// MARK: - Errors

/// An errno as FSKit wants it. Replying with anything else makes the kernel
/// report EIO, which tells whoever is watching nothing at all.
func fsError(_ code: POSIXError.Code) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
}
