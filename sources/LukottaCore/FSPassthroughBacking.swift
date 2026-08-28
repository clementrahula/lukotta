// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// `FSPassthrough`, behind the same seam.
///
/// The passthrough names its files by where they are rather than by holding
/// them, so a handle has to carry the entry. It is re-read on every call that
/// depends on the file's current state: a size or a modification time captured
/// when the handle was made is one that was true once, and FSKit holds a handle
/// for the whole life of a file.
public final class FSPassthroughBacking: FSBacking, @unchecked Sendable {

    /// A handle on a file in the directory underneath. The URL is what is
    /// stable; everything else is looked up again when it is asked for.
    public final class Handle: FSHandle {
        public let url: URL
        public init(url: URL) {
            self.url = url
            super.init()
        }
    }

    private let store: FSPassthrough
    private let rootURL: URL

    public init(root: URL) {
        self.store = FSPassthrough(root: root)
        self.rootURL = root
    }

    private func entry(_ handle: FSHandle) -> FSPassthrough.Entry? {
        guard let handle = handle as? Handle else { return nil }
        return store.entry(at: handle.url)
    }

    public var rootHandle: FSHandle { Handle(url: rootURL) }

    public func attributes(of handle: FSHandle) -> FSAttributes? {
        guard let handle = handle as? Handle, let entry = store.entry(at: handle.url) else {
            return nil
        }
        let parent = handle.url.deletingLastPathComponent()
        return FSAttributes(
            id: entry.id,
            // The parent's own identifier, which Finder uses to walk back up.
            // The root is its own parent, as it is on any volume.
            parentID: store.entry(at: parent)?.id ?? entry.id,
            isDirectory: entry.isDirectory, size: entry.size, mode: entry.mode,
            linkCount: entry.linkCount, modified: entry.modified, created: entry.created)
    }

    public func setMode(_ mode: UInt32, on handle: FSHandle) {
        guard let handle = handle as? Handle else { return }
        _ = chmod(handle.url.path, mode_t(mode))
    }

    public func lookup(_ name: String, in directory: FSHandle) -> FSHandle? {
        guard let directory = directory as? Handle, let entry = entry(directory),
            let found = store.lookup(name, in: entry)
        else { return nil }
        return Handle(url: found.url)
    }

    public func children(of directory: FSHandle) -> [(name: String, handle: FSHandle)] {
        guard let directory = directory as? Handle, let entry = entry(directory) else { return [] }
        return store.children(of: entry).map {
            ($0.url.lastPathComponent, Handle(url: $0.url) as FSHandle)
        }
    }

    public func create(
        _ name: String, isDirectory: Bool, in directory: FSHandle, mode: UInt32
    ) -> FSHandle? {
        guard let directory = directory as? Handle, let entry = entry(directory),
            let made = store.create(name, isDirectory: isDirectory, in: entry, mode: mode)
        else { return nil }
        return Handle(url: made.url)
    }

    public func remove(_ name: String, from directory: FSHandle) -> FSStore.RemoveOutcome {
        guard let directory = directory as? Handle, let entry = entry(directory) else {
            return .missing
        }
        return store.remove(name, from: entry)
    }

    public func rename(
        _ name: String, in source: FSHandle, to newName: String, in destination: FSHandle
    ) -> Bool {
        guard let source = source as? Handle, let destination = destination as? Handle,
            let from = entry(source), let to = entry(destination)
        else { return false }
        return store.rename(name, in: from, to: newName, in: to)
    }

    public func read(_ handle: FSHandle, offset: Int, length: Int) -> Data {
        guard let entry = entry(handle) else { return Data() }
        return store.read(entry, offset: offset, length: length)
    }

    public func write(_ handle: FSHandle, contents: Data, offset: Int) -> Int {
        guard let entry = entry(handle) else { return 0 }
        return store.write(entry, contents: contents, offset: offset)
    }

    public func truncate(_ handle: FSHandle, to size: Int) {
        guard let entry = entry(handle) else { return }
        store.truncate(entry, to: size)
    }

    public func xattr(_ name: String, of handle: FSHandle) -> Data? {
        guard let entry = entry(handle) else { return nil }
        return store.xattr(name, of: entry)
    }

    public func xattrNames(of handle: FSHandle) -> [String] {
        guard let entry = entry(handle) else { return [] }
        return store.xattrNames(of: entry)
    }

    public func setXattr(
        _ name: String, to value: Data?, on handle: FSHandle,
        mustCreate: Bool, mustReplace: Bool
    ) -> FSStore.XattrOutcome {
        guard let entry = entry(handle) else { return .missing }
        return store.setXattr(
            name, to: value, on: entry, mustCreate: mustCreate, mustReplace: mustReplace)
    }

    public func usage() -> (files: UInt64, bytes: UInt64) { store.usage() }
}
