// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import FSKit
import Foundation
import LukottaCore

/// An FSItem carrying a handle on whatever is behind the seam.
///
/// FSKit hands the same object back on every later call about that file, so the
/// identity has to be the item rather than a name looked up again each time.
final class Item: FSItem {
    let handle: FSHandle
    init(_ handle: FSHandle) {
        self.handle = handle
        super.init()
    }
}

/// A Lukotta volume, over whatever is holding the files.
///
/// Written once against FSBacking: memory prices the framework and nothing
/// else, a real directory prices the write path against a backing store that is
/// not the bottleneck, and the thing that ships puts a guest holding the NTFS
/// volume there instead. The volume cannot tell them apart, which is the whole
/// point of the seam.
///
/// Every reply is made on the thread FSKit called in on. Nothing here hops to
/// an actor or a queue of its own: the crossing is what is being measured, and
/// adding a scheduler would measure the scheduler. Under Swift 6 a closure
/// written inside actor-isolated code traps outright when an Objective-C API
/// calls it back on its own queue -- see AGENTS.md.
final class LukottaVolume: FSVolume, @unchecked Sendable {

    private let store: any FSBacking
    private let rootItem: Item
    private let volumeName: String

    init(name: String, backing: any FSBacking) {
        self.store = backing
        self.rootItem = Item(backing.rootHandle)
        self.volumeName = name
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: FSFileName(string: name))
    }

    // MARK: - Attributes

    private func attributes(of handle: FSHandle) -> FSItem.Attributes? {
        guard let source = store.attributes(of: handle) else { return nil }
        let attributes = FSItem.Attributes()
        attributes.fileID = FSItem.Identifier(rawValue: source.id) ?? .invalid
        attributes.parentID = FSItem.Identifier(rawValue: source.parentID) ?? .invalid
        attributes.type = source.isDirectory ? .directory : .file
        attributes.mode = source.mode
        attributes.linkCount = source.linkCount
        attributes.size = source.size
        // Rounded to a block, as a real filesystem reports it: du and Finder's
        // "size on disk" both read this rather than size.
        attributes.allocSize = (source.size + 4095) / 4096 * 4096
        attributes.uid = UInt32(getuid())
        attributes.gid = UInt32(getgid())
        attributes.flags = 0
        // Kernel-offloaded I/O is off for everything this volume serves.
        //
        // KOIO is how an FSKit module reaches the throughput of a kernel
        // filesystem: instead of moving file data through the module, it hands
        // the kernel a map of extents and the kernel transfers them itself.
        // FSExtentPacker.packExtent takes an FSBlockDeviceResource, so the data
        // has to physically live on a block device the kernel can address.
        //
        // Neither backing here is one. Memory is memory, and the passthrough is
        // a directory on another filesystem -- there are no physical extents to
        // hand over. Saying so explicitly means the kernel uses the read/write
        // path rather than asking for a map that cannot be made.
        attributes.inhibitKernelOffloadedIO = true
        let modified = timespec(
            tv_sec: Int(source.modified.timeIntervalSince1970), tv_nsec: 0)
        let created = timespec(tv_sec: Int(source.created.timeIntervalSince1970), tv_nsec: 0)
        attributes.modifyTime = modified
        attributes.changeTime = modified
        attributes.accessTime = modified
        attributes.birthTime = created
        attributes.addedTime = created
        return attributes
    }
}

// MARK: - The required operations

extension LukottaVolume: FSVolume.Operations {

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
        reply(attributes(of: item.handle), nil)
    }

    func setAttributes(
        _ new: FSItem.SetAttributesRequest, on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else {
            return reply(nil, fsError(POSIXError.EINVAL))
        }
        if new.consumedAttributes.contains(.mode) {
            store.setMode(new.mode, on: item.handle)
        }
        if new.consumedAttributes.contains(.size) {
            store.truncate(item.handle, to: Int(new.size))
        }
        reply(attributes(of: item.handle), nil)
    }

    func lookupItem(
        named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? Item, let string = name.string else {
            return reply(nil, nil, fsError(POSIXError.EINVAL))
        }
        guard let handle = store.lookup(string, in: directory.handle) else {
            return reply(nil, nil, fsError(POSIXError.ENOENT))
        }
        reply(Item(handle), name, nil)
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
            let handle = store.create(
                string, isDirectory: type == .directory, in: directory.handle, mode: mode)
        else {
            return reply(nil, nil, fsError(POSIXError.EEXIST))
        }
        reply(Item(handle), name, nil)
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
        switch store.remove(string, from: directory.handle) {
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
        if overItem != nil { _ = store.remove(to, from: destination.handle) }
        guard store.rename(from, in: source.handle, to: to, in: destination.handle) else {
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
        let entries = store.children(of: directory.handle)
        // The cookie is where the last call stopped. Names are sorted, so the
        // same index means the same entry on the next call.
        var index = Int(cookie.rawValue)
        while index < entries.count {
            let entry = entries[index]
            index += 1
            guard let facts = store.attributes(of: entry.handle) else { continue }
            let packed = packer.packEntry(
                name: FSFileName(string: entry.name),
                itemType: facts.isDirectory ? .directory : .file,
                itemID: FSItem.Identifier(rawValue: facts.id) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: UInt64(index)),
                attributes: attributes == nil ? nil : self.attributes(of: entry.handle))
            // Packing stops when the buffer the kernel gave us is full. What is
            // left is asked for again with the cookie we just handed over.
            if !packed { break }
        }
        reply(verifier, nil)
    }
}

// MARK: - Reading and writing

extension LukottaVolume: FSVolume.ReadWriteOperations {

    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else { return reply(0, fsError(POSIXError.EINVAL)) }
        let slice = store.read(item.handle, offset: Int(offset), length: length)
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
        reply(store.write(item.handle, contents: contents, offset: Int(offset)), nil)
    }
}

// MARK: - Errors

/// An errno as FSKit wants it. Replying with anything else makes the kernel
/// report EIO, which tells whoever is watching nothing at all.
func fsError(_ code: POSIXError.Code) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
}

// MARK: - Extended attributes

/// Answering these natively is what stops macOS writing an AppleDouble file
/// beside every file on the volume.
///
/// macOS attaches `com.apple.provenance` to everything it creates. Where the
/// filesystem cannot hold an xattr, the client writes a `._name` file instead:
/// measured on the NFS volume this application serves today, 6000 files created
/// came with 6000 sidecars, so every create cost two. A volume that answers
/// getxattr and setxattr itself never gets one.
extension LukottaVolume: FSVolume.XattrOperations {

    func getXattr(
        named name: FSFileName, of item: FSItem,
        replyHandler reply: @escaping (Data?, (any Error)?) -> Void
    ) {
        guard let item = item as? Item, let key = name.string else {
            return reply(nil, fsError(POSIXError.EINVAL))
        }
        guard let value = store.xattr(key, of: item.handle) else {
            // ENOATTR, which is what a caller checking for an attribute that is
            // not there expects. ENOENT would mean the file is gone.
            return reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOATTR)))
        }
        reply(value, nil)
    }

    func setXattr(
        named name: FSFileName, to value: Data?, on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let item = item as? Item, let key = name.string else {
            return reply(fsError(POSIXError.EINVAL))
        }
        switch store.setXattr(
            key, to: value, on: item.handle,
            mustCreate: policy == .mustCreate, mustReplace: policy == .mustReplace)
        {
        case .set: reply(nil)
        case .exists: reply(fsError(POSIXError.EEXIST))
        case .missing: reply(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOATTR)))
        }
    }

    func listXattrs(
        of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else { return reply(nil, fsError(POSIXError.EINVAL)) }
        reply(store.xattrNames(of: item.handle).map { FSFileName(string: $0) }, nil)
    }
}

// MARK: - Opening and closing

/// FSKit tells the module when a file is opened and closed so that a
/// filesystem which needs to hold something per-open can. This one does not,
/// and says so: `openCloseInhibited` stops the kernel making the calls at all,
/// which is two crossings saved on every single file anybody opens.
///
/// Measured reason to care: a crossing that misses the VFS cache costs ~200 us
/// against the kernel's 5. Operations a module does not need are operations it
/// should not be asked to answer.
extension LukottaVolume: FSVolume.OpenCloseOperations {

    var isOpenCloseInhibited: Bool { true }

    func openItem(
        _ item: FSItem, modes: FSVolume.OpenModes,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func closeItem(
        _ item: FSItem, modes: FSVolume.OpenModes,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }
}
