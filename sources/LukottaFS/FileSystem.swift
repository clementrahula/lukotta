// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import ExtensionFoundation
import FSKit
import Foundation
import LukottaCore

/// The extension macOS loads to serve a Lukotta volume.
///
/// What it serves today is memory, and that is on purpose: see Store.swift. The
/// shape -- probe, load, a volume answering the VFS -- is the shape the real one
/// needs, so what is measured through this is what the real one will pay before
/// it has done any work of its own.
final class LukottaFileSystem: FSUnaryFileSystem, @unchecked Sendable {
    // Held so the volume outlives the reply that handed it over. FSKit keeps
    // no strong reference of its own, and a volume released here comes back as
    // a mount that answers nothing.
    private var volume: LukottaVolume?
}

extension LukottaFileSystem: FSUnaryFileSystemOperations {

    /// Whether this module can serve what it has been handed.
    ///
    /// A block device is read and identified, by the same `BootSector.identify`
    /// the rest of the application uses to decide what a drive holds. One
    /// reader, so the extension and the drive list cannot disagree about what a
    /// disk is -- and they would, eventually, if this had a signature table of
    /// its own.
    ///
    /// What it claims is deliberately narrow. Saying "usable" for a filesystem
    /// macOS already handles would take that volume away from the driver that
    /// handles it properly, which is a worse outcome than not appearing at all.
    /// So: NTFS and the two encrypted containers, and nothing else.
    ///
    /// Anything that is not a block device -- the memory case, which is what a
    /// measurement mounts -- is accepted, because there is nothing to read and
    /// nothing to be wrong about.
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let device = resource as? FSBlockDeviceResource else {
            return reply(
                .usable(name: "Lukotta", containerID: FSContainerIdentifier(uuid: UUID())), nil)
        }

        var sector = [UInt8](repeating: 0, count: 4096)
        let read: Int
        do {
            read = try sector.withUnsafeMutableBytes {
                try device.read(into: $0, startingAt: 0, length: $0.count)
            }
        } catch {
            // Unreadable is not "not ours": it is a question that could not be
            // asked, and claiming the volume on a failed read would take it
            // from whatever can read it.
            return reply(.notRecognized, nil)
        }

        let format = BootSector.identify(Data(sector.prefix(max(0, read))))
        guard ExtensionMount.claims(format) else { return reply(.notRecognized, nil) }
        reply(
            .usable(name: format.name, containerID: FSContainerIdentifier(uuid: UUID())), nil)
    }

    func loadResource(
        resource: FSResource, options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        // Which backing this serves is the one decision this makes, and it is
        // read from the mount options rather than the environment: an appex is
        // launched by fskitd, not by whoever ran the command, so it inherits no
        // environment at all. This read LUKOTTA_FS_ROOT once, which meant it
        // was unset in the only situation it existed for.
        //
        //     mount -F -t lukottafs -o root=/some/directory device point
        //
        // Memory prices the framework; a real directory prices the write path
        // against a store that is not the bottleneck, which is the measurement
        // FAT32 cannot give. What ships names the guest's volume here.
        let backing: any FSBacking
        if let root = FSMountOptions.backingRoot(options.taskOptions) {
            backing = FSPassthroughBacking(root: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            backing = FSStoreBacking()
        }
        let volume = LukottaVolume(name: "Lukotta", backing: backing)
        self.volume = volume
        reply(volume, nil)
    }

    func unloadResource(
        resource: FSResource, options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        volume = nil
        reply(nil)
    }
}

/// The extension point. macOS starts this process and asks it for its
/// filesystem; everything else arrives as calls on the volume above.
@main
struct LukottaFSExtension: UnaryFileSystemExtension {
    var fileSystem: LukottaFileSystem { LukottaFileSystem() }
}
