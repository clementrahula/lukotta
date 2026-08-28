// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The tree this module serves, held entirely in memory.
///
/// Deliberately the fastest backing store there is. The question this extension
/// exists to answer is what FSKit itself costs per operation, and every measured
/// filesystem so far has answered a different question: Apple's msdos module
/// costs 1686 us to create a file, but FAT32 walks an allocation chain and scans
/// a linear directory to do it, so the number describes FAT and not the
/// framework. With nothing but a dictionary underneath, whatever a create costs
/// here is what crossing into a user-space module costs, and nothing else.
///
/// It is therefore not a filesystem anybody should keep anything in. It forgets
/// everything when it is unmounted, which for a measurement is a feature.
///
/// Unchecked and locked by hand rather than an actor. FSKit calls in on its own
/// queues and expects a reply on the thread it called from; hopping to an actor
/// would put a scheduler in the middle of the very cost being measured, and
/// under Swift 6 a closure written inside actor-isolated code traps outright
/// when an Objective-C API calls it back on a queue of its own. See AGENTS.md,
/// "A Closure Handed to an Objective-C API".
final class Store: @unchecked Sendable {

    /// One file or directory. A class rather than a struct so that the item
    /// FSKit holds on to and the one in the tree are the same object: FSKit
    /// hands back the FSItem it was given and expects it to still mean
    /// something.
    final class Node {
        let id: UInt64
        var name: String
        let isDirectory: Bool
        var data: Data
        var children: [String: Node]
        weak var parent: Node?
        var created: Date
        var modified: Date
        var mode: UInt32

        init(id: UInt64, name: String, isDirectory: Bool, parent: Node?, mode: UInt32) {
            self.id = id
            self.name = name
            self.isDirectory = isDirectory
            self.data = Data()
            self.children = [:]
            self.parent = parent
            let now = Date()
            self.created = now
            self.modified = now
            self.mode = mode
        }

        var size: UInt64 { isDirectory ? 0 : UInt64(data.count) }

        /// What a directory reports as its link count: itself, its entry in its
        /// parent, and one per child directory. Finder shows a folder as empty
        /// when this is wrong.
        var linkCount: UInt32 {
            guard isDirectory else { return 1 }
            return UInt32(2 + children.values.filter(\.isDirectory).count)
        }
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 2
    let root: Node

    init() {
        // 1 is reserved; a root of 2 is what a real volume reports.
        root = Node(id: 2, name: "", isDirectory: true, parent: nil, mode: 0o755)
        nextID = 3
    }

    private func claimID() -> UInt64 {
        nextID += 1
        return nextID
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - The operations the volume forwards

    func lookup(_ name: String, in directory: Node) -> Node? {
        withLock { directory.children[name] }
    }

    func create(_ name: String, isDirectory: Bool, in directory: Node, mode: UInt32) -> Node? {
        withLock {
            guard directory.isDirectory, directory.children[name] == nil else { return nil }
            let node = Node(
                id: claimID(), name: name, isDirectory: isDirectory,
                parent: directory, mode: mode)
            directory.children[name] = node
            directory.modified = Date()
            return node
        }
    }

    /// Whether the name was there to take away. A directory with anything in it
    /// is refused, which is what ENOTEMPTY means.
    enum RemoveOutcome { case removed, missing, notEmpty }

    func remove(_ name: String, from directory: Node) -> RemoveOutcome {
        withLock {
            guard let node = directory.children[name] else { return .missing }
            if node.isDirectory, !node.children.isEmpty { return .notEmpty }
            directory.children.removeValue(forKey: name)
            node.parent = nil
            directory.modified = Date()
            return .removed
        }
    }

    func rename(
        _ name: String, in source: Node, to newName: String, in destination: Node
    ) -> Bool {
        withLock {
            guard let node = source.children[name] else { return false }
            source.children.removeValue(forKey: name)
            node.name = newName
            node.parent = destination
            destination.children[newName] = node
            let now = Date()
            source.modified = now
            destination.modified = now
            return true
        }
    }

    func children(of directory: Node) -> [Node] {
        // Sorted, so that a directory enumerated twice comes back in the same
        // order. FSKit resumes an enumeration from a cookie that is an index
        // into this, and an order that moves between calls skips entries.
        withLock { directory.children.values.sorted { $0.name < $1.name } }
    }

    func read(_ node: Node, offset: Int, length: Int) -> Data {
        withLock {
            guard offset < node.data.count else { return Data() }
            let end = min(node.data.count, offset + length)
            return node.data.subdata(in: offset..<end)
        }
    }

    func write(_ node: Node, contents: Data, offset: Int) -> Int {
        withLock {
            let end = offset + contents.count
            if node.data.count < end {
                node.data.append(Data(count: end - node.data.count))
            }
            node.data.replaceSubrange(offset..<end, with: contents)
            node.modified = Date()
            return contents.count
        }
    }

    func truncate(_ node: Node, to size: Int) {
        withLock {
            if size < node.data.count {
                node.data.removeSubrange(size..<node.data.count)
            } else if size > node.data.count {
                node.data.append(Data(count: size - node.data.count))
            }
            node.modified = Date()
        }
    }

    /// Everything in the tree, for the statfs reply.
    func usage() -> (files: UInt64, bytes: UInt64) {
        withLock {
            var files: UInt64 = 0
            var bytes: UInt64 = 0
            var stack = [root]
            while let node = stack.popLast() {
                files += 1
                bytes += node.size
                stack.append(contentsOf: node.children.values)
            }
            return (files, bytes)
        }
    }
}
