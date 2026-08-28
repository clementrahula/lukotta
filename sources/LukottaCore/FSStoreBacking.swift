// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// `FSStore`, behind the seam every volume is written against.
///
/// A wrapper rather than a conformance on the store itself. `FSStore.Node` is
/// an `FSHandle`, so a conformance would give every method two overloads that
/// both match -- `children(of: node)` becoming ambiguous at every call site,
/// including the ones that have nothing to do with the extension. The store
/// keeps its own plain API and this adapts it.
///
/// Each call unwraps the handle it was given. A handle from another backing is
/// a programming error rather than something to recover from, and answering it
/// as "not found" is what stops that mistake becoming a wrong answer about
/// somebody's disk.
public final class FSStoreBacking: FSBacking, @unchecked Sendable {

    private let store: FSStore

    public init(_ store: FSStore = FSStore()) {
        self.store = store
    }

    private func node(_ handle: FSHandle) -> FSStore.Node? { handle as? FSStore.Node }

    public var rootHandle: FSHandle { store.root }

    public func attributes(of handle: FSHandle) -> FSAttributes? {
        guard let node = node(handle) else { return nil }
        return store.withLock {
            FSAttributes(
                id: node.id, parentID: node.parent?.id ?? node.id,
                isDirectory: node.isDirectory, size: node.size, mode: node.mode,
                linkCount: node.linkCount, modified: node.modified, created: node.created)
        }
    }

    public func setMode(_ mode: UInt32, on handle: FSHandle) {
        guard let node = node(handle) else { return }
        store.withLock { node.mode = mode }
    }

    public func lookup(_ name: String, in directory: FSHandle) -> FSHandle? {
        guard let directory = node(directory) else { return nil }
        return store.lookup(name, in: directory)
    }

    public func children(of directory: FSHandle) -> [(name: String, handle: FSHandle)] {
        guard let directory = node(directory) else { return [] }
        return store.children(of: directory).map { ($0.name, $0 as FSHandle) }
    }

    public func create(
        _ name: String, isDirectory: Bool, in directory: FSHandle, mode: UInt32
    ) -> FSHandle? {
        guard let directory = node(directory) else { return nil }
        return store.create(name, isDirectory: isDirectory, in: directory, mode: mode)
    }

    public func remove(_ name: String, from directory: FSHandle) -> FSStore.RemoveOutcome {
        guard let directory = node(directory) else { return .missing }
        return store.remove(name, from: directory)
    }

    public func rename(
        _ name: String, in source: FSHandle, to newName: String, in destination: FSHandle
    ) -> Bool {
        guard let source = node(source), let destination = node(destination) else { return false }
        return store.rename(name, in: source, to: newName, in: destination)
    }

    public func read(_ handle: FSHandle, offset: Int, length: Int) -> Data {
        guard let node = node(handle) else { return Data() }
        return store.read(node, offset: offset, length: length)
    }

    public func write(_ handle: FSHandle, contents: Data, offset: Int) -> Int {
        guard let node = node(handle) else { return 0 }
        return store.write(node, contents: contents, offset: offset)
    }

    public func truncate(_ handle: FSHandle, to size: Int) {
        guard let node = node(handle) else { return }
        store.truncate(node, to: size)
    }

    public func xattr(_ name: String, of handle: FSHandle) -> Data? {
        guard let node = node(handle) else { return nil }
        return store.xattr(name, of: node)
    }

    public func xattrNames(of handle: FSHandle) -> [String] {
        guard let node = node(handle) else { return [] }
        return store.xattrNames(of: node)
    }

    public func setXattr(
        _ name: String, to value: Data?, on handle: FSHandle,
        mustCreate: Bool, mustReplace: Bool
    ) -> FSStore.XattrOutcome {
        guard let node = node(handle) else { return .missing }
        return store.setXattr(
            name, to: value, on: node, mustCreate: mustCreate, mustReplace: mustReplace)
    }

    public func usage() -> (files: UInt64, bytes: UInt64) { store.usage() }
}
