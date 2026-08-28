// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import ExtensionFoundation
import FSKit
import Foundation

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
    private var volume: MemoryVolume?
}

extension LukottaFileSystem: FSUnaryFileSystemOperations {

    /// Whether this module can serve what it has been handed.
    ///
    /// It says yes to anything. A module that probes properly reads the
    /// resource and recognises a signature; this one is not deciding whether a
    /// disk is ours, it is standing in for one while the cost of the framework
    /// around it is measured. The real module reuses BootSector.swift here.
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        reply(
            .usable(
                name: "Lukotta", containerID: FSContainerIdentifier(uuid: UUID())),
            nil)
    }

    func loadResource(
        resource: FSResource, options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        let volume = MemoryVolume(name: "Lukotta")
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
