// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A handle on one file or directory, as the extension holds it.
///
/// FSKit hands the same object back on every later call about a file and expects
/// it to still mean that file, so identity has to be the handle rather than a
/// name looked up again. A class, and a shared base, so that a volume can be
/// written once against whatever is underneath it.
public class FSHandle {
    public init() {}
}

/// What a file looks like to the kernel, without any of FSKit's types in it.
///
/// Kept plain so that LukottaCore does not import FSKit: FSKit needs macOS 15.4
/// and the application supports 15.0, so nothing outside the extension may
/// depend on it. The extension turns this into `FSItem.Attributes`.
public struct FSAttributes: Sendable, Equatable {
    public var id: UInt64
    public var parentID: UInt64
    public var isDirectory: Bool
    public var size: UInt64
    public var mode: UInt32
    public var linkCount: UInt32
    public var modified: Date
    public var created: Date

    public init(
        id: UInt64, parentID: UInt64, isDirectory: Bool, size: UInt64,
        mode: UInt32, linkCount: UInt32, modified: Date, created: Date
    ) {
        self.id = id
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.size = size
        self.mode = mode
        self.linkCount = linkCount
        self.modified = modified
        self.created = created
    }
}

/// Everything the volume asks of whatever is holding the files.
///
/// Two things implement it. `FSStore` keeps them in memory, which prices the
/// framework and nothing else. `FSPassthrough` keeps them in a real directory,
/// which is what measures the write path against a backing store that is not
/// the bottleneck, and is the shape the real one takes: the architecture puts a
/// module in front and a guest holding the NTFS volume behind it, and the seam
/// between them is exactly this.
///
/// Every call answers on the thread it was made on. FSKit calls in on its own
/// queues and expects the reply there, and under Swift 6 a closure written
/// inside actor-isolated code traps outright when an Objective-C API calls it
/// back on a queue of its own -- see AGENTS.md, "A Closure Handed to an
/// Objective-C API". So nothing here is an actor and nothing hops.
public protocol FSBacking: AnyObject, Sendable {
    var rootHandle: FSHandle { get }

    func attributes(of handle: FSHandle) -> FSAttributes?
    func setMode(_ mode: UInt32, on handle: FSHandle)

    func lookup(_ name: String, in directory: FSHandle) -> FSHandle?
    func children(of directory: FSHandle) -> [(name: String, handle: FSHandle)]
    /// The part of a directory a page of an enumeration needs.
    ///
    /// A listing is asked for a page at a time, and handing back the whole of a
    /// directory each time is what makes listing a large one cost the square of
    /// its size. The default is the whole list sliced, which is right for a
    /// backing small enough not to care.
    func children(of directory: FSHandle, from: Int, limit: Int)
        -> [(name: String, handle: FSHandle)]
    func create(_ name: String, isDirectory: Bool, in directory: FSHandle, mode: UInt32)
        -> FSHandle?
    func remove(_ name: String, from directory: FSHandle) -> FSStore.RemoveOutcome
    func rename(_ name: String, in source: FSHandle, to newName: String, in destination: FSHandle)
        -> Bool

    func read(_ handle: FSHandle, offset: Int, length: Int) -> Data
    func write(_ handle: FSHandle, contents: Data, offset: Int) -> Int
    func truncate(_ handle: FSHandle, to size: Int)

    func xattr(_ name: String, of handle: FSHandle) -> Data?
    func xattrNames(of handle: FSHandle) -> [String]
    func setXattr(
        _ name: String, to value: Data?, on handle: FSHandle, mustCreate: Bool, mustReplace: Bool
    ) -> FSStore.XattrOutcome

    func usage() -> (files: UInt64, bytes: UInt64)

    /// How large the volume is, in bytes.
    ///
    /// Zero means "no fixed size", which is true of the memory backing and of a
    /// directory on somebody else's filesystem. The extension invents a size
    /// for those, because Finder refuses to copy onto a volume that reports
    /// none free -- but it must not invent one for a real disk, where the
    /// number is knowable and wrong would show in Get Info.
    var capacityInBytes: UInt64 { get }

    /// How much of the disk the smallest file takes.
    ///
    /// `du` and Finder's "size on disk" both report the space a file occupies
    /// rather than its length, and the difference is a whole block. Zero means
    /// there is no such thing here, and the caller should not invent one.
    var blockSizeInBytes: Int { get }
}

extension FSBacking {
    /// Backings with nothing real behind them do not have to answer.
    public var capacityInBytes: UInt64 { 0 }

    /// Backings with nothing real behind them have no block size either.
    public var blockSizeInBytes: Int { 0 }

    public func children(of directory: FSHandle, from: Int, limit: Int)
        -> [(name: String, handle: FSHandle)]
    {
        let all = children(of: directory)
        guard from >= 0, from < all.count, limit > 0 else { return [] }
        return Array(all[from..<min(all.count, from + limit)])
    }
}
