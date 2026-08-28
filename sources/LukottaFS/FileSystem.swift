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
        var name = "Lukotta"
        let backing: any FSBacking
        if let device = resource as? FSBlockDeviceResource {
            // What is on it decides what can be done with it. The probe claims
            // BitLocker and LUKS as well as NTFS, because a locked drive is
            // still ours to open -- but opening one needs a key, and a
            // filesystem extension has nowhere to ask for a passphrase.
            //
            // So an encrypted volume is refused here, deliberately and with the
            // reason written down. The decrypting reader exists and is checked
            // (DecryptingReader, AESXTS); what is missing is the key, which
            // means unwrapping BitLocker's FVEK or deriving LUKS's, and a way
            // for the application to hand it over. Serving the ciphertext as a
            // filesystem would present a drive full of noise.
            let held = HeldDevice(device)
            if let boot = held.read(0, 4096) {
                let format = BootSector.identify(boot)
                if format == .bitlocker || format == .luks {
                    Log.app.notice(
                        "the drive is encrypted (\(format.name, privacy: .public)) and the extension has no key for it yet"
                    )
                    return reply(nil, fsError(POSIXError.ENOTSUP))
                }
            }
            // The real thing: an NTFS volume, read straight off the device.
            // Every read the volume makes comes back through here, so the
            // parsers never learn what a block device is.
            guard let ntfs = NTFSBacking(read: { offset, length in held.read(offset, length) })
            else {
                // Not NTFS, or a table that cannot be read. Refusing is the
                // answer: a volume served empty looks like a drive that lost
                // everything on it.
                return reply(nil, fsError(POSIXError.EINVAL))
            }
            backing = ntfs
            // The drive's own name, which is what Finder puts on the desktop.
            // Calling every volume "Lukotta" would be this application putting
            // its own name on somebody else's disk.
            name = ntfs.volumeLabel ?? name
        } else if let root = FSMountOptions.backingRoot(options.taskOptions) {
            backing = FSPassthroughBacking(root: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            backing = FSStoreBacking()
        }
        let volume = LukottaVolume(name: name, backing: backing)
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

/// A block device, carried into the reader's closure.
///
/// `FSBlockDeviceResource` is not `Sendable`, and the closure it is used from
/// is: the reader is handed to a backing that FSKit calls on its own queues.
/// Wrapping it is a claim, so here is the basis for it.
///
/// Every call arrives through `NTFSBacking`, which takes a lock around each one,
/// so no two reads of this device overlap. The resource is never mutated -- only
/// `read` is called, and the buffer belongs to this function. And it outlives
/// the closure, because FSKit holds the resource for as long as the volume is
/// mounted, which is longer than the backing that reads from it.
///
/// If any of those three stops being true, this is where the reasoning is
/// written down and where it has to be revisited.
final class HeldDevice: @unchecked Sendable {
    private let device: FSBlockDeviceResource

    init(_ device: FSBlockDeviceResource) {
        self.device = device
    }

    func read(_ offset: UInt64, _ length: Int) -> Data? {
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = try? buffer.withUnsafeMutableBytes {
            try device.read(into: $0, startingAt: off_t(offset), length: length)
        }
        guard let read, read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }
}
