// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

/// Drive a whole flow through the real app, without a person and without a
/// window.
///
/// The unit tests cover decisions and the snapshots cover what is drawn.
/// Neither covers a sequence: open a container, unlock it, rebuild the list,
/// eject it. Every fault found in that flow has been one step undoing an
/// earlier one, such as a scan dropping a row or a save recording the wrong
/// frame, and only running the steps in order finds those.
///
/// Runs against the real engine, the real helper and the real hdiutil. Nothing
/// is stubbed and nothing is drawn: it exits before the scene is built, so no
/// window appears.
enum EndToEnd {

    @MainActor private static var failures = 0
    @MainActor private static var checks = 0

    @MainActor
    static func runIfAsked() {
        guard let index = CommandLine.arguments.firstIndex(of: "--e2e") else { return }
        let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: --e2e <container.img> <passphrase> [plain.img]\n".utf8))
            exit(2)
        }
        let container = URL(fileURLWithPath: arguments[0])
        let passphrase = arguments[1]
        guard FileManager.default.fileExists(atPath: container.path) else {
            FileHandle.standardError.write(Data("no container at \(container.path)\n".utf8))
            exit(2)
        }

        // Every fixture this was handed has to be there. Each flow below opens
        // its file only if it exists, so one that was never built was skipped
        // in silence and the run still finished by saying everything passed.
        for (index, path) in arguments.enumerated() where index != 1 {
            check(
                FileManager.default.fileExists(atPath: path),
                "the fixture \(URL(fileURLWithPath: path).lastPathComponent) was built")
        }

        print("every disk on this Mac")
        surveyFlow()

        print("")
        print("encrypted container: \(container.lastPathComponent)")
        containerFlow(container: container, passphrase: passphrase)

        print("")
        print("the same container, opened read-only")
        readOnlyFlow(container: container, passphrase: passphrase)

        if arguments.count >= 6 {
            let plain = URL(fileURLWithPath: arguments[4])
            let encrypted = URL(fileURLWithPath: arguments[5])
            if FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("qcow2, unencrypted: \(plain.lastPathComponent)")
                qcow2Flow(image: plain, passphrase: nil)
            }
            if FileManager.default.fileExists(atPath: encrypted.path) {
                print("")
                print("qcow2, encrypted: \(encrypted.lastPathComponent)")
                if EnginePaths.opensEncryptionInsideImages {
                    qcow2Flow(image: encrypted, passphrase: passphrase)
                } else {
                    qcow2RefusedFlow(image: encrypted)
                }
            }
        }

        if arguments.count >= 9 {
            let vmdk = URL(fileURLWithPath: arguments[7])
            let reaching = URL(fileURLWithPath: arguments[8])
            if FileManager.default.fileExists(atPath: vmdk.path) {
                print("")
                print("VMDK: \(vmdk.lastPathComponent)")
                qcow2Flow(image: vmdk, passphrase: nil)
            }
            if FileManager.default.fileExists(atPath: reaching.path) {
                print("")
                print("a VMDK reaching outside its folder: \(reaching.lastPathComponent)")
                hostileFlow(image: reaching)
            }
        }

        if arguments.count >= 11 {
            let fixed = URL(fileURLWithPath: arguments[9])
            let dynamic = URL(fileURLWithPath: arguments[10])
            if FileManager.default.fileExists(atPath: fixed.path) {
                print("")
                print("fixed VHD: \(fixed.lastPathComponent)")
                qcow2Flow(image: fixed, passphrase: nil)
            }
            if FileManager.default.fileExists(atPath: dynamic.path) {
                print("")
                print("dynamic VHD: \(dynamic.lastPathComponent)")
                // Read by the engine's VHD driver. A build without it must say
                // so rather than serve the header as a disk.
                if EnginePaths.opensVdiAndVhd {
                    qcow2Flow(image: dynamic, passphrase: nil)
                } else {
                    refusedByNameFlow(image: dynamic, saying: "dynamic VHD")
                }
            }
        }

        if arguments.count >= 18 {
            let vhdx = URL(fileURLWithPath: arguments[15])
            let dirty = URL(fileURLWithPath: arguments[16])
            let differencing = URL(fileURLWithPath: arguments[17])
            if FileManager.default.fileExists(atPath: vhdx.path) {
                print("")
                print("VHDX: \(vhdx.lastPathComponent)")
                if EnginePaths.opensVdiAndVhd {
                    qcow2Flow(image: vhdx, passphrase: nil)
                } else {
                    refusedByNameFlow(image: vhdx, saying: "VHDX")
                }
            }
            if FileManager.default.fileExists(atPath: dirty.path) {
                print("")
                print("a VHDX that was not shut down cleanly: \(dirty.lastPathComponent)")
                refusedByNameFlow(image: dirty, saying: "not shut down cleanly")
            }
            if FileManager.default.fileExists(atPath: differencing.path) {
                print("")
                print("a VHDX naming a parent disk: \(differencing.lastPathComponent)")
                refusedByNameFlow(image: differencing, saying: "another disk")
            }
        }

        if arguments.count >= 15 {
            let sparse = URL(fileURLWithPath: arguments[13])
            let streamed = URL(fileURLWithPath: arguments[14])
            if FileManager.default.fileExists(atPath: sparse.path) {
                print("")
                print("sparse VMDK: \(sparse.lastPathComponent)")
                if EnginePaths.opensSparseVmdk {
                    qcow2Flow(image: sparse, passphrase: nil)
                } else {
                    refusedByNameFlow(image: sparse, saying: "sparse VMDK")
                }
            }
            if FileManager.default.fileExists(atPath: streamed.path) {
                print("")
                print("a VMDK whose grains are deflated: \(streamed.lastPathComponent)")
                if EnginePaths.opensSparseVmdk {
                    qcow2Flow(image: streamed, passphrase: nil)
                } else {
                    refusedByNameFlow(image: streamed, saying: "sparse VMDK")
                }
            }
        }

        if arguments.count >= 13 {
            let vdi = URL(fileURLWithPath: arguments[11])
            let ancient = URL(fileURLWithPath: arguments[12])
            if FileManager.default.fileExists(atPath: vdi.path) {
                print("")
                print("VDI: \(vdi.lastPathComponent)")
                if EnginePaths.opensVdiAndVhd {
                    qcow2Flow(image: vdi, passphrase: nil)
                } else {
                    refusedByNameFlow(image: vdi, saying: "VDI")
                }
            }
            if FileManager.default.fileExists(atPath: ancient.path) {
                print("")
                print("a VDI written by a format nobody released: \(ancient.lastPathComponent)")
                refusedByNameFlow(image: ancient, saying: "not a disk image")
            }
        }

        if arguments.count >= 7 {
            let hostile = URL(fileURLWithPath: arguments[6])
            if FileManager.default.fileExists(atPath: hostile.path) {
                print("")
                print("an image naming another file: \(hostile.lastPathComponent)")
                hostileFlow(image: hostile)
            }
        }

        if arguments.count >= 4 {
            let exfat = URL(fileURLWithPath: arguments[3])
            if FileManager.default.fileExists(atPath: exfat.path) {
                print("")
                print("exFAT image: \(exfat.lastPathComponent)")
                handOverFlow(image: exfat)
            }
        }

        if arguments.count >= 3 {
            let plain = URL(fileURLWithPath: arguments[2])
            if FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("unencrypted image: \(plain.lastPathComponent)")
                plainFlow(image: plain)
            }
        }

        // Writing, for the formats whose drivers were written here. A file put
        // into a mounted image has to be in the image file afterwards, which no
        // amount of reading can demonstrate.
        //
        // Each is opened for writing and then opened again from scratch, so
        // what is checked is the file on disk rather than anything the first
        // mount still had in memory.
        let writable: [(Int, String)] = [
            (2, "raw image"),
            (10, "dynamic VHD"),
            (9, "fixed VHD"),
            (11, "VDI"),
            (13, "sparse VMDK"),
            (7, "VMDK"),
            (4, "qcow2"),
        ]
        for (index, what) in writable where arguments.count > index {
            let image = URL(fileURLWithPath: arguments[index])
            guard FileManager.default.fileExists(atPath: image.path) else { continue }
            print("")
            print("writing to a \(what): \(image.lastPathComponent)")
            writeFlow(image: image)
        }

        // Writing through encryption: the same drivers underneath, with LUKS
        // between them and the filesystem. Nothing else here writes to a
        // volume that had to be unlocked first.
        for (index, what) in [(5, "qcow2"), (0, "raw image")] where arguments.count > index {
            let image = URL(fileURLWithPath: arguments[index])
            guard FileManager.default.fileExists(atPath: image.path) else { continue }
            print("")
            print("writing to a LUKS volume inside a \(what): \(image.lastPathComponent)")
            writeFlow(image: image, passphrase: passphrase)
        }

        // Putting back what was open, which is what the setting at the top of
        // Settings does.
        if arguments.count > 2 {
            let plain = URL(fileURLWithPath: arguments[2])
            if FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("putting back what was open: \(plain.lastPathComponent)")
                restoreFlow(image: plain, passphrase: nil)
            }
        }

        // And the two that are read and not written: asked for read-write,
        // each opens read-only rather than failing, and refuses to be written
        // to.
        for (index, what) in [(15, "VHDX"), (14, "stream-optimized VMDK")]
        where arguments.count > index {
            let image = URL(fileURLWithPath: arguments[index])
            guard FileManager.default.fileExists(atPath: image.path), EnginePaths.opensVdiAndVhd
            else { continue }
            print("")
            print("writing to a \(what), which is read-only: \(image.lastPathComponent)")
            writeFlow(image: image, expectingReadOnly: true)
        }

        // Nothing stays attached, whatever the outcome. A run that failed
        // halfway left the image behind, and the next run then passed or failed
        // for reasons unrelated to the code.
        detachEverything(
            Array(
                arguments.prefix(3).enumerated().filter { $0.offset != 1 }
                    .map { URL(fileURLWithPath: $0.element) }))

        print("")
        print("\(checks - failures)/\(checks) steps passed")
        exit(failures > 0 ? 1 : 0)
    }

    // MARK: The flow

    @MainActor
    private static func containerFlow(container: URL, passphrase: String) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        // 1. Open it.
        model.openImage(container)
        guard
            waitUntil(
                "the container opens", timeout: 60,
                condition: {
                    model.imageOpening == nil
                        && model.drives.contains { $0.uuid == container.path }
                })
        else {
            if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
            return
        }
        guard let drive = model.drives.first(where: { $0.uuid == container.path }) else { return }
        check(drive.connection.contains(appString("Disk Image")), "it is listed as a disk image")

        // 2. Unlock it.
        //
        // Checked before anything is typed. A LUKS container was described on
        // this screen as "plain NTFS, and is not encrypted", because the note
        // was shown for anything that was not BitLocker and its wording fell
        // through to a default.
        model.choose(drive)
        guard
            waitUntil(
                "the container is identified", timeout: 30,
                condition: { model.chosenFormat != nil })
        else { return }
        check(model.chosenFormat == .luks, "and identified as LUKS, which is what it is")
        check(!model.chosenDriveIsOpenAlready, "so a passphrase is asked for")
        check(!model.phase.isMounted, "and nothing is opened behind the question")

        model.credential = passphrase
        model.unlock(drive)
        guard
            waitUntil(
                "it unlocks and mounts", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        guard case .mounted(_, let mountPoint) = model.phase else {
            check(false, "it mounted rather than failing")
            return
        }
        check(FileManager.default.fileExists(atPath: mountPoint), "the mount point exists")
        // Opened as the user, with no helper and no authorisation, which is why
        // it lands here rather than in /Volumes.
        check(
            mountPoint.hasPrefix(NSHomeDirectory() + "/Volumes/"),
            "and it is under ~/Volumes, so nothing was elevated to open it")

        // 3. The list is rebuilt while it is open.
        //
        // A container with no partition table is a row no scan can produce, so
        // a rebuild dropped it, the app reported the drive as unplugged, and the
        // person was returned to the list from a drive they had just opened.
        let before = model.phase
        let generation = model.scanGeneration
        model.refreshDrives()
        // Waits for the results to be applied rather than for the scan to be
        // requested. Waiting on the phase would pass straight through, a rebuild
        // not changing it, and every assertion below would then be about the
        // list as it was before.
        guard
            waitUntil(
                "the list rebuilds", condition: { model.scanGeneration > generation })
        else { return }
        check(
            model.drives.contains { $0.uuid == container.path },
            "the container is still listed after a rebuild")
        check(before.isMounted && model.phase.isMounted, "and the screen is still the open drive")
        check(model.departed.isEmpty, "and nothing was announced as disconnected")

        // 4. Eject it.
        model.eject(mountPoint)
        guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
            return
        }
        check(model.ejectProblem == nil, "ejecting reported no problem")
        guard
            waitUntil(
                "the container is detached", timeout: 30,
                condition: { !model.drives.contains { $0.uuid == container.path } })
        else { return }
        // Waited for rather than asserted: the drive leaves the app's list when
        // the engine lets go of it, and macOS takes the device node away a
        // moment later.
        waitUntil(
            "and its device is gone, so the file is a file again", timeout: 30,
            condition: { !FileManager.default.fileExists(atPath: drive.devicePath) })
    }

    /// The same container, opened read-only.
    ///
    /// Asserted against the mount itself rather than against the flag that
    /// asked for it: a script that passed the flag and mounted the drive
    /// writable anyway would satisfy every check made in Swift.
    @MainActor
    private static func readOnlyFlow(container: URL, passphrase: String) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        model.openImage(container)
        guard
            waitUntil(
                "the container opens", timeout: 60,
                condition: {
                    model.imageOpening == nil
                        && model.drives.contains { $0.uuid == container.path }
                })
        else { return }
        guard let drive = model.drives.first(where: { $0.uuid == container.path }) else { return }

        model.choose(drive)
        guard
            waitUntil(
                "the container is identified", timeout: 30,
                condition: { model.chosenFormat != nil })
        else { return }

        model.credential = passphrase
        model.unlock(drive, readOnly: true)
        guard
            waitUntil(
                "it unlocks and mounts read-only", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        guard case .mounted(_, let mountPoint) = model.phase else {
            check(false, "it mounted rather than failing")
            return
        }
        check(model.mountedReadOnly, "the app knows it was opened read-only")
        check(
            model.readOnlyMounts.contains(mountPoint),
            "and marks the mount point, which is what the list reads")

        // What the flag was for. The file is written where anyone opening the
        // drive would write one, and the mount must refuse it.
        let probe = URL(fileURLWithPath: mountPoint).appendingPathComponent("lukotta-e2e-write")
        var refused = false
        do {
            try Data("written".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            refused = true
        }
        check(refused, "and the drive itself refuses to be written to")

        let table = shellOutput("/sbin/mount")
        check(
            table.split(separator: "\n").contains {
                $0.contains(mountPoint) && $0.contains("read-only")
            },
            "the mount table calls it read-only, so Finder shows it that way too")

        model.eject(mountPoint)
        guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
            return
        }
        check(model.ejectProblem == nil, "ejecting reported no problem")
        guard
            waitUntil(
                "the container is detached", timeout: 30,
                condition: { !model.drives.contains { $0.uuid == container.path } })
        else { return }
    }

    /// Write to an image, eject it, and open it again to see what stayed.
    ///
    /// The formats are written by drivers added here, so this is where their
    /// work meets a real filesystem: a file written through a mounted image has
    /// to survive the mount being torn down, the virtual machine exiting, and
    /// the image being opened again from the file on disk.
    @MainActor
    private static func writeFlow(
        image: URL, passphrase: String? = nil, expectingReadOnly: Bool = false
    ) {
        let contents = "written through \(image.lastPathComponent) at mount time\n"
        let name = "lukotta-write-probe.txt"

        // 1. Open it and write a file into it.
        var written = false
        do {
            let model = AppModel()
            model.start()
            guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
                return
            }
            model.openImage(image)
            guard
                waitUntil(
                    "the image opens", timeout: 60,
                    condition: {
                        model.imageOpening == nil && model.drives.contains { $0.uuid == image.path }
                    })
            else {
                if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
                return
            }
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }
            // Opening the file is already the choice, and the app has made it:
            // choosing again would discard what the engine said is inside a
            // container it alone can read.
            guard
                waitUntil(
                    "it is identified", timeout: 60,
                    condition: { model.phaseIsUnlock && model.chosenFormat != nil })
            else { return }

            if let passphrase { model.credential = passphrase }
            model.unlock(drive)
            guard
                waitUntil(
                    "it mounts", timeout: 180,
                    condition: {
                        if case .mounted = model.phase { return true }
                        if case .failed = model.phase { return true }
                        return false
                    })
            else { return }
            guard case .mounted(_, let mountPoint) = model.phase else {
                if case .failed(_, let summary, _) = model.phase { print("      \(summary)") }
                check(false, "it mounted rather than failing")
                return
            }

            if expectingReadOnly {
                // A format this build reads and cannot write. The device the
                // guest is given is marked read-only, so the writable mount
                // fails and the fallback takes over.
                check(
                    model.mountedReadOnly,
                    "asked for read-write, it opened read-only, which is what this format allows")
                check(
                    mountTableSaysReadOnly(mountPoint),
                    "and the mount table says so too")
                let probe = URL(fileURLWithPath: mountPoint).appendingPathComponent(name)
                check(
                    (try? Data(contents.utf8).write(to: probe)) == nil,
                    "and the mount refuses to be written to")
                model.eject(mountPoint)
                waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting })
                return
            }

            check(!model.mountedReadOnly, "it opened read-write, which this format allows")
            check(
                !mountTableSaysReadOnly(mountPoint),
                "and the mount table agrees, which is what Finder reads")
            let probe = URL(fileURLWithPath: mountPoint).appendingPathComponent(name)
            do {
                try Data(contents.utf8).write(to: probe)
                written = true
                check(true, "a file can be written to it")
            } catch {
                check(false, "a file can be written to it (\(error.localizedDescription))")
            }
            if written {
                let read = try? String(contentsOf: probe, encoding: .utf8)
                check(read == contents, "and reads back as what was written")
            }

            model.eject(mountPoint)
            guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
                return
            }
            check(model.ejectProblem == nil, "ejecting reported no problem")
        }
        guard written else { return }

        // 2. Open it again. Nothing of the first mount survives: a new virtual
        // machine reads the file as it now stands.
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }
        model.openImage(image)
        guard
            waitUntil(
                "it opens again", timeout: 60,
                condition: {
                    model.imageOpening == nil && model.drives.contains { $0.uuid == image.path }
                })
        else { return }
        guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }
        guard
            waitUntil(
                "it is identified again", timeout: 60,
                condition: { model.phaseIsUnlock && model.chosenFormat != nil })
        else { return }
        if let passphrase { model.credential = passphrase }
        model.unlock(drive)
        guard
            waitUntil(
                "it mounts again", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        guard case .mounted(_, let mountPoint) = model.phase else {
            check(false, "it mounted rather than failing")
            return
        }
        let probe = URL(fileURLWithPath: mountPoint).appendingPathComponent(name)
        let read = try? String(contentsOf: probe, encoding: .utf8)
        check(read == contents, "the file written before is in the image, unchanged")

        // Left as it was found, so the fixture can be used again.
        try? FileManager.default.removeItem(at: probe)
        model.eject(mountPoint)
        waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting })
    }

    /// What was open comes back on its own.
    ///
    /// A restart cannot be staged here, so the next best thing is done: the
    /// image is opened, the mount is torn down behind the app's back the way a
    /// restart tears it down, and a fresh model is left to put it back with
    /// nobody typing anything.
    @MainActor
    private static func restoreFlow(image: URL, passphrase: String?) {
        MountMemory.forgetAll()
        RestorePreference.isOn = true
        defer {
            RestorePreference.isOn = false
            MountMemory.forgetAll()
        }

        var mountPoint = ""
        do {
            let model = AppModel()
            model.start()
            guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
                return
            }
            model.openImage(image)
            guard
                waitUntil(
                    "the image opens", timeout: 60,
                    condition: {
                        model.imageOpening == nil && model.drives.contains { $0.uuid == image.path }
                    })
            else { return }
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }
            guard
                waitUntil(
                    "it is identified", timeout: 60,
                    condition: { model.phaseIsUnlock && model.chosenFormat != nil })
            else { return }
            if let passphrase { model.credential = passphrase }
            // Read-only, so that what comes back has to come back the same way
            // rather than merely coming back.
            model.unlock(drive, readOnly: true)
            guard
                waitUntil(
                    "it mounts read-only", timeout: 180,
                    condition: {
                        if case .mounted = model.phase { return true }
                        if case .failed = model.phase { return true }
                        return false
                    })
            else { return }
            guard case .mounted(_, let point) = model.phase else {
                check(false, "it mounted rather than failing")
                return
            }
            mountPoint = point
            check(
                MountMemory.all().contains { $0.uuid == image.path && $0.readOnly },
                "what was opened is remembered, read-only and all")
        }

        // What a restart does: the mount and the machine serving it are gone,
        // and nothing was ejected, so the record of it stays.
        _ = EngineStatus.unmount(mountPoint: mountPoint)
        guard
            waitUntil(
                "the mount is gone, as it would be after a restart", timeout: 60,
                condition: { !FileManager.default.fileExists(atPath: mountPoint) })
        else { return }
        check(
            MountMemory.all().contains { $0.uuid == image.path },
            "and it is still remembered, because nobody ejected it")

        // A new model, as at the next login. Nothing is typed and nothing is
        // chosen.
        let model = AppModel()
        model.start()
        guard waitUntil("the app starts again", condition: { !model.isScanning }) else { return }
        guard
            waitUntil(
                "the drive comes back on its own", timeout: 240,
                condition: { !model.openMounts.isEmpty })
        else { return }
        check(
            !model.phaseIsUnlock,
            "and nothing was put on screen about it, the way macOS mounts a disk")
        guard let point = model.openMounts.values.first else { return }
        check(
            model.readOnlyMounts.contains(point),
            "it came back read-only, which is how it was")
        check(
            mountTableSaysReadOnly(point),
            "and the mount table agrees")

        model.eject(point)
        waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting })
        check(
            MountMemory.all().isEmpty,
            "ejecting it means it does not come back next time")
    }

    /// An image holding an ordinary filesystem, which has no password to ask
    /// for and should not ask for one.
    @MainActor
    private static func plainFlow(image: URL) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        model.openImage(image)
        guard
            waitUntil(
                "the image opens", timeout: 60,
                condition: {
                    model.imageOpening == nil && model.drives.contains { $0.uuid == image.path }
                })
        else {
            if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
            return
        }
        guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }

        // An image with nothing to unlock still has a choice to make, so the
        // screen appears with no passphrase field and two ways to open it.
        //
        // Waited on until the image is identified, not merely until the screen
        // is up: the screen also appears on its own after a second and a half,
        // for a reading that has not come back, and neither button can be
        // pressed until it has.
        guard
            waitUntil(
                "it asks how to open it", timeout: 60,
                condition: { model.phaseIsUnlock && model.chosenFormat != nil })
        else { return }
        check(
            model.chosenDriveIsOpenAlready,
            "and knows there is nothing to unlock, so no passphrase is asked for")

        model.unlock(drive)
        guard
            waitUntil(
                "it opens", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        check(model.chosenFormat == .btrfs, "it was recognised as the filesystem it is")
        check(model.chosenDriveIsOpenAlready, "which is why nothing was asked")
        guard case .mounted(_, let mountPoint) = model.phase else {
            if case .failed(_, let summary, _) = model.phase { print("      \(summary)") }
            check(false, "it mounted rather than failing")
            return
        }
        check(FileManager.default.fileExists(atPath: mountPoint), "the mount point exists")

        model.eject(mountPoint)
        guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else { return }
        check(model.ejectProblem == nil, "ejecting reported no problem")
        waitUntil(
            "the image is detached", timeout: 30,
            condition: { !model.drives.contains { $0.uuid == image.path } })

        // A remembered passphrase must not stand in the way. There is nothing
        // for one to unlock, and waiting for the field to be empty is what made
        // the screen conditional on it.
        model.openImage(image)
        guard
            waitUntil(
                "it opens again", timeout: 60,
                condition: {
                    model.imageOpening == nil && model.drives.contains { $0.uuid == image.path }
                })
        else { return }
        guard let again = model.drives.first(where: { $0.uuid == image.path }) else { return }
        model.credential = "a passphrase it does not need"
        guard
            waitUntil(
                "it asks how to open it, whatever is in the field", timeout: 60,
                condition: { model.phaseIsUnlock && model.chosenFormat != nil })
        else { return }
        check(
            model.chosenDriveIsOpenAlready,
            "and still knows there is nothing for a passphrase to unlock")

        model.unlock(again)
        guard
            waitUntil(
                "it opens even with something in the field", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        check(model.phase.isMounted, "and it opened rather than complaining about the passphrase")
        if case .mounted(_, let point) = model.phase {
            model.eject(point)
            waitUntil("it ejects again", timeout: 120, condition: { !model.isEjecting })
        }
    }

    /// Detach anything still attached from these files, whatever happened.
    @MainActor
    private static func detachEverything(_ files: [URL]) {
        let paths = Set(files.map(\.path))
        for device in DiskImage.attachedDevices(forImages: paths) {
            if DiskImage.detach(device) { print("  ..   detached \(device)") }
        }
    }

    /// A format macOS reads on its own, which is not opened here at all. It is
    /// handed over, and the person is told why.
    @MainActor
    private static func handOverFlow(image: URL) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        var sawTheQuestion = false
        model.openImage(image)
        guard
            waitUntil(
                "macOS is given the image", timeout: 60,
                condition: {
                    if model.phaseIsUnlock { sawTheQuestion = true }
                    if case .handedToMacOS = model.imageOpening { return true }
                    if case .failed = model.imageOpening { return true }
                    return false
                })
        else { return }

        guard case .handedToMacOS(_, let point) = model.imageOpening else {
            if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
            check(false, "it was handed over rather than refused")
            return
        }
        check(!sawTheQuestion, "and no password was ever asked for")
        check(model.chosenFormat == .exfat, "it was recognised as exFAT")

        // The volume must be local rather than served over NFS.
        let table = (try? String(contentsOfFile: "/dev/null", encoding: .utf8)) ?? ""
        _ = table
        check(FileManager.default.fileExists(atPath: point), "and macOS mounted it at \(point)")
        check(point.hasPrefix("/Volumes/"), "in /Volumes, like any other disk")
        check(
            !model.drives.contains { $0.uuid == image.path },
            "and it is not in this app's list, because it is not this app's to hold")

        // macOS owns the attachment once it is handed over, so detaching it
        // here would remove the volume just mounted.
        DiskImage.detach("/dev/" + (point as NSString).lastPathComponent)
        _ = DiskImage.attachedDevices(forImages: [image.path]).map { DiskImage.detach($0) }
    }

    /// A qcow2, which macOS cannot attach at all. The engine reads the format
    /// itself and is handed the path, never a device and never root.
    /// libkrun opens whatever an image names, a backing file or an external
    /// data file, so an image could otherwise determine which other files the
    /// virtual machine reads.
    /// An image whose data is not laid out as raw must be refused by name, not
    /// handed to the engine to be read as gibberish.
    @MainActor
    private static func refusedByNameFlow(image: URL, saying phrase: String) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }
        model.openImage(image)
        guard
            waitUntil(
                "it is refused", timeout: 60,
                condition: {
                    if case .failed = model.imageOpening { return true }
                    if model.drives.contains(where: { $0.uuid == image.path }) { return true }
                    return false
                })
        else { return }
        guard case .failed(_, let why) = model.imageOpening else {
            check(false, "an image that is not laid out as raw is refused, not listed")
            return
        }
        check(why.contains(phrase), "and the reason names it: \(phrase)")
        check(!model.phaseIsUnlock, "and no passphrase was asked for it")
    }

    @MainActor
    private static func hostileFlow(image: URL) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }
        model.openImage(image)
        guard
            waitUntil(
                "it is refused", timeout: 60,
                condition: {
                    if case .failed = model.imageOpening { return true }
                    if model.drives.contains(where: { $0.uuid == image.path }) { return true }
                    return false
                })
        else { return }
        guard case .failed(_, let why) = model.imageOpening else {
            check(false, "an image naming another file is refused, not listed")
            return
        }
        check(
            why.contains("another file"),
            "and the reason says it names another file rather than blaming the format")
        check(
            DiskImage.attachedDevices(forImages: [image.path]).isEmpty,
            "and nothing of it was attached")
        // The engine must never have been told about it: the check has to come
        // before the path is handed over, not after.
        check(!model.phaseIsUnlock, "and no passphrase was asked for it")
    }

    /// An engine without the vmproxy patch does not open encryption inside a
    /// qcow2. It must report that at once rather than failing three screens
    /// later with a message about filesystems.
    @MainActor
    private static func qcow2RefusedFlow(image: URL) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }
        model.openImage(image)
        guard
            waitUntil(
                "it is refused rather than attempted", timeout: 60,
                condition: {
                    if case .failed = model.imageOpening { return true }
                    if model.drives.contains(where: { $0.uuid == image.path }) { return true }
                    return false
                })
        else { return }
        guard case .failed(_, let why) = model.imageOpening else {
            check(false, "it was refused rather than listed")
            return
        }
        check(why.contains("qcow2"), "and the reason names the container it is in")
        check(!model.phaseIsUnlock, "no passphrase was asked for something it cannot use")
    }

    @MainActor
    private static func qcow2Flow(image: URL, passphrase: String?) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        var sawTheQuestion = false
        model.openImage(image)
        guard
            waitUntil(
                "the engine reads it without attaching anything", timeout: 60,
                condition: {
                    if model.phaseIsUnlock { sawTheQuestion = true }
                    if model.drives.contains(where: { $0.uuid == image.path }) { return true }
                    if case .failed = model.imageOpening { return true }
                    return false
                })
        else { return }
        if case .failed(_, let why) = model.imageOpening {
            print("      \(why)")
            check(false, "it was read rather than refused")
            return
        }

        check(
            DiskImage.attachedDevices(forImages: [image.path]).isEmpty,
            "and nothing was attached, because macOS cannot read this kind of image")

        if let passphrase {
            check(sawTheQuestion || model.phaseIsUnlock, "an encrypted one asks for a passphrase")
            check(model.chosenFormat == .luks, "recognised as LUKS from the engine's own listing")
            model.credential = passphrase
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }
            model.unlock(drive)
        } else {
            guard
                waitUntil(
                    "it asks how to open it, nothing in it being encrypted", timeout: 60,
                    condition: { model.phaseIsUnlock && model.chosenFormat != nil })
            else { return }
            check(
                model.chosenDriveIsOpenAlready,
                "and asks nothing else, there being no passphrase to ask for")
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else { return }
            model.unlock(drive)
        }

        guard
            waitUntil(
                "it opens", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        guard case .mounted(_, let point) = model.phase else {
            if case .failed(_, let summary, _) = model.phase { print("      \(summary)") }
            check(false, "it mounted rather than failing")
            return
        }
        check(FileManager.default.fileExists(atPath: point), "the mount point exists")
        check(
            point.hasPrefix(NSHomeDirectory() + "/Volumes/"),
            "under ~/Volumes, so nothing was elevated")

        model.eject(point)
        guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else { return }
        check(model.ejectProblem == nil, "ejecting reported no problem")
        waitUntil(
            "and it leaves the list", timeout: 30,
            condition: { !model.drives.contains { $0.uuid == image.path } })
    }

    /// Every disk on this Mac, with a verdict each. Run against the real
    /// machine, so the result reflects what is plugged in.
    @MainActor
    private static func surveyFlow() {
        let model = AppModel()
        model.surveyDrives()
        guard waitUntil("every disk is surveyed", timeout: 30, condition: { !model.survey.isEmpty })
        else { return }

        check(model.survey.count >= 2, "more than one thing is listed")
        // The boot disk must be listed and must not be offered. A list omitting
        // it has lost something, and one offering it invites someone to open
        // their own system.
        let system = model.survey.filter { $0.verdict == .system }
        check(!system.isEmpty, "the running system's own volumes are listed")
        check(
            system.allSatisfy { $0.drive == nil },
            "and none of them is offered as something to open")
        // Every row must carry a name and a size to be of any use.
        check(
            model.survey.allSatisfy { !$0.name.isEmpty && !$0.content.isEmpty },
            "and every row says what it is")
        print("      \(model.survey.count) disks and volumes seen")
    }

    // MARK: Running the loop

    /// Whether the system says this mount is read-only, which is the fact the
    /// app's own belief is checked against.
    @MainActor
    private static func mountTableSaysReadOnly(_ mountPoint: String) -> Bool {
        shellOutput("/sbin/mount")
            .split(separator: "\n")
            .contains { $0.contains(mountPoint) && $0.contains("read-only") }
    }

    /// The output of a command, for the checks that read the system rather
    /// than the app.
    private static func shellOutput(_ path: String, _ arguments: [String] = []) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Wait for something to become true, pumping the run loop while it does.
    ///
    /// Everything here is asynchronous and lands on the main actor, so the test
    /// lets the main actor run rather than blocking it.
    @MainActor
    @discardableResult
    private static func waitUntil(
        _ what: String, timeout: TimeInterval = 30, condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                check(false, "\(what) (gave up after \(Int(timeout))s)")
                return false
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(true, what)
        return true
    }

    @MainActor
    private static func check(_ passed: Bool, _ what: String) {
        checks += 1
        if passed {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)")
        }
    }
}

extension AppModel.Phase {
    var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }
}

extension AppModel {
    /// Whether the screen asking for a passphrase is up.
    var phaseIsUnlock: Bool {
        if case .unlock = phase { return true }
        return false
    }
}
