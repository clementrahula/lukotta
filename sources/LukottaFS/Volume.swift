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
        // "size on disk" both read this rather than size. The block is the
        // volume's own -- an NTFS volume can be formatted with anything from
        // 512 bytes to 64 KB, and rounding everything to four thousand and
        // ninety-six reports the wrong number on most of them.
        let block = store.blockSizeInBytes
        attributes.allocSize =
            block > 0
            ? (source.size + UInt64(block) - 1) / UInt64(block) * UInt64(block) : source.size
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
        // **The NTFS backing is one, and this is the one thing left on the
        // table.** It reads and writes an FSBlockDeviceResource, so its files
        // do have physical extents, and handing the kernel a map of them is how
        // an FSKit module reaches the throughput of a kernel filesystem instead
        // of moving every byte through a process.
        //
        // It stays off because the map is not built yet. Saying a file can be
        // offloaded and then failing to describe where it is would be worse
        // than not offering: the kernel asks for a map, gets nothing, and the
        // read fails rather than falling back. The other two backings can never
        // offer it -- memory is memory, and a directory on somebody else's
        // filesystem has no extents of its own to give.
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
        // A real disk knows how large it is. Only the backings with nothing
        // behind them -- memory, a directory on somebody else's filesystem --
        // get an invented gigabyte, because Finder refuses to copy onto a
        // volume that reports no free space at all.
        let blockSize: UInt64 = 4096
        let declared = store.capacityInBytes
        let total: UInt64 = declared > 0 ? declared : (1 << 30)
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

    /// The volume is being let go.
    ///
    /// **This is where the dirty flag comes off.** While the volume is mounted
    /// it carries a mark saying somebody without a journal is writing to it,
    /// and a mount that ends without clearing it leaves a drive Windows runs
    /// chkdsk on for nothing -- and that this filesystem itself refuses to
    /// write to next time, because a marked volume is one with work
    /// outstanding.
    ///
    /// Failing to clear it is not reported as a failure of the deactivation.
    /// The mount is ending either way; refusing here would leave the volume
    /// mounted and still marked, which is the same state and harder to get out
    /// of.
    func deactivate(
        options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        release()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        // Again, because a volume can be unmounted without being deactivated
        // first and the two are not ordered. Releasing twice is harmless: the
        // second one finds nothing to clear.
        release()
        reply()
    }

    func synchronize(
        flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        // Every write here has already gone to the device by the time it
        // returns -- there is no buffer behind this to flush, which is what
        // makes a sync cheap and a power cut no worse than the last write.
        reply(nil)
    }

    /// Put the volume's dirty flag back, if this volume has one to put back.
    ///
    /// Only an NTFS backing carries a mark; the ones that keep files in memory
    /// or in a directory have nothing to release, and asking them is not an
    /// error.
    private func release() {
        (store as? NTFSBacking)?.release()
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
            // Why it failed decides what somebody is told. A name already in
            // the directory is EEXIST; anything else -- no free record, no room
            // in the node, a volume that must not be written to -- is a full
            // disk as far as whoever asked is concerned. Reporting EEXIST for
            // all of them tells a person a file is already there when it is
            // not, and they go looking for it.
            let taken = store.lookup(string, in: directory.handle) != nil
            return reply(nil, nil, fsError(taken ? POSIXError.EEXIST : POSIXError.ENOSPC))
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
        //
        // **The rename is tried first.** Removing what is in the way and then
        // finding the rename cannot be done -- no room in the node, a volume
        // that turned read-only -- destroys a file to accomplish nothing.
        // Trying first costs an attempt that fails on the name being taken,
        // and only then is anything removed.
        if store.rename(from, in: source.handle, to: to, in: destination.handle) {
            return reply(destinationName, nil)
        }
        guard overItem != nil, store.remove(to, from: destination.handle) == .removed,
            store.rename(from, in: source.handle, to: to, in: destination.handle)
        else {
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
        // The cookie is where the last call stopped, and the arithmetic for it
        // lives in LukottaCore where it can be checked: one off in either
        // direction makes a file vanish from the folder or appear twice, and
        // neither reads as an error. Names come back sorted, so the same index
        // means the same entry on the next call.
        // Only the part of the directory this page can hold, rather than all of
        // it. A page that copies the whole listing costs the size of the
        // directory, once per page, which on a large one is the size squared.
        // The number is generous: packing stops when the kernel's buffer is
        // full, and asking for more than fits costs a slice and not a read.
        let start = Int(cookie.rawValue)
        let entries = store.children(of: directory.handle, from: start, limit: 4096)
        for step in DirectoryEnumeration.steps(entries.map(\.name), from: 0) {
            let index = Int(step.nextCookie) - 1
            guard index >= 0, index < entries.count else { break }
            let entry = entries[index]
            guard let facts = store.attributes(of: entry.handle) else { continue }
            let packed = packer.packEntry(
                name: FSFileName(string: entry.name),
                itemType: facts.isDirectory ? .directory : .file,
                itemID: FSItem.Identifier(rawValue: facts.id) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: UInt64(start) + step.nextCookie),
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
        let written = store.write(item.handle, contents: contents, offset: Int(offset))
        // Nothing stored, when something was asked for, is not a short write.
        // Reported as one, the kernel asks again for the same bytes and gets
        // the same answer, and a copy either spins or ends silently truncated
        // -- somebody is told their file was copied and half of it is there.
        // The honest answer is that there was no room.
        if written == 0, !contents.isEmpty {
            return reply(0, fsError(POSIXError.ENOSPC))
        }
        reply(written, nil)
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
        // The filesystem does not keep extended attributes at all, which is
        // what makes macOS write them into a `._` file beside the real one
        // instead of treating the refusal as a fault.
        case .unsupported: reply(fsError(POSIXError.ENOTSUP))
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

// MARK: - Access checks

/// Who may open what.
///
/// Every drive this application opens is opened by one person, on their own
/// Mac, because they asked for it. The permissions written on the files came
/// from whatever system last owned the drive -- a Windows install, another
/// Linux machine, a NAS -- and mean nothing about who is sitting here now. v1
/// says the same thing to the engine as `--ignore-permissions`, and the volume
/// reports every file as owned by whoever opened the drive.
///
/// So the check is inhibited rather than answered permissively: the kernel does
/// not ask at all, which is a crossing saved on every open rather than a
/// crossing spent saying yes.
extension LukottaVolume: FSVolume.AccessCheckOperations {

    var isAccessCheckInhibited: Bool { true }

    /// Anybody may do anything, which is the right answer for a removable
    /// drive and not laziness.
    ///
    /// NTFS keeps permissions as Windows security descriptors in `$Secure`,
    /// naming Windows accounts. There is no honest mapping from those to the
    /// user sitting at this Mac -- the same drive plugged into two machines
    /// would answer differently, and refusing somebody their own files because
    /// a Windows account they have never heard of owns them is the worst thing
    /// this application could do. Every other NTFS driver for macOS answers the
    /// same way, and v1 does too.
    func checkAccess(
        to item: FSItem, requestedAccess access: FSVolume.AccessMask,
        replyHandler reply: @escaping (Bool, (any Error)?) -> Void
    ) {
        reply(true, nil)
    }
}

// MARK: - Letting go of an item

/// When FSKit is finished with a file for now.
///
/// The volume holds nothing per-item that has to be torn down: a handle is a
/// node in a tree or a URL, and both are cheap and owned by the backing rather
/// than by FSKit's view of them. So there is nothing to do here, and the policy
/// says never rather than answering a call that would do nothing.
///
/// The alternative -- accepting the calls and returning immediately -- costs a
/// crossing per file, on a path where a crossing that misses the cache measured
/// 200 us against the kernel's 5. An operation a module does not need is an
/// operation it should not be asked to answer.
extension LukottaVolume: FSVolume.ItemDeactivation {

    var itemDeactivationPolicy: FSVolume.ItemDeactivationOptions { [] }

    func deactivateItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
}

// MARK: - Renaming the volume

/// Renaming the drive itself, from Finder's Get Info.
///
/// Refused, and refused rather than silently ignored. A drive opened by this
/// application belongs to whatever wrote it -- a Windows install, a camera, a
/// NAS -- and its label lives in the filesystem's own metadata. Writing a new
/// one means writing to a drive somebody asked us to open, which is a thing
/// this application does not do, and getting it wrong on NTFS means editing the
/// boot sector of a volume that is not ours.
///
/// `volumeRenameInhibited` is what tells Finder so before anybody types
/// anything: the field is not offered, rather than offered and then rejected
/// with an error nobody can act on.
extension LukottaVolume: FSVolume.RenameOperations {

    var isVolumeRenameInhibited: Bool { true }

    func setVolumeName(
        _ name: FSFileName, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, fsError(POSIXError.EPERM))
    }
}

// MARK: - Reserving space before a write

/// `F_PREALLOCATE`, which is what a large copy asks for before it starts.
///
/// Finder and anything else moving a big file ask for the space up front so
/// that a copy fails at the beginning rather than nine tenths of the way
/// through. Answering it honestly is worth a crossing: a refusal makes the
/// caller fall back to writing and discovering, which is the slow and
/// disappointing order.
///
/// The memory backing has nothing to reserve and the passthrough is a directory
/// on a filesystem doing its own allocation, so neither can promise blocks. What
/// both can do is grow the file to the length asked for, which is what makes the
/// caller's next write land in space that already exists.
extension LukottaVolume: FSVolume.PreallocateOperations {

    func preallocateSpace(
        for item: FSItem, at offset: off_t, length: Int, flags: FSVolume.PreallocateFlags,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? Item else { return reply(0, fsError(POSIXError.EINVAL)) }
        guard let facts = store.attributes(of: item.handle) else {
            return reply(0, fsError(POSIXError.EIO))
        }
        let wanted = Int(offset) + length
        guard wanted > Int(facts.size) else {
            // Already that long. Nothing was allocated and nothing failed.
            return reply(0, nil)
        }
        store.truncate(item.handle, to: wanted)
        guard let after = store.attributes(of: item.handle), after.size >= UInt64(wanted) else {
            return reply(0, fsError(POSIXError.ENOSPC))
        }
        reply(wanted - Int(facts.size), nil)
    }
}
