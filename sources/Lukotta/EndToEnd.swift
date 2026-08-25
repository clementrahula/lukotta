// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

// The test harnesses are built into the pre-release and into a plain local
// build, and out of the app people are given: nobody running Lukotta has a use
// for a flag that renders every screen or opens every fixture, and what is not
// compiled in cannot be reached by passing one.
#if DEVTOOLS

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
            // Fixtures arrive as name=path. Addressed by position, adding one
            // meant counting arguments on both sides of the command line, and the
            // guards protecting indices 15 to 17 were written in a different order
            // from the hand-over.
            var fixtures: [String: URL] = [:]
            var passphrase = ""
            for argument in CommandLine.arguments.dropFirst(index + 1) {
                guard let equals = argument.firstIndex(of: "=") else { continue }
                let key = String(argument[argument.startIndex..<equals])
                let value = String(argument[argument.index(after: equals)...])
                if key == "passphrase" {
                    passphrase = value
                } else {
                    fixtures[key] = URL(fileURLWithPath: value)
                }
            }
            guard let container = fixtures["container"], !passphrase.isEmpty else {
                FileHandle.standardError.write(
                    Data("usage: --e2e container=<path> passphrase=<word> name=<path>…\n".utf8))
                exit(2)
            }
            guard FileManager.default.fileExists(atPath: container.path) else {
                FileHandle.standardError.write(Data("no container at \(container.path)\n".utf8))
                exit(2)
            }

            // Every fixture this was handed has to be there. Each flow below opens
            // its file only if it exists, so one that was never built was skipped
            // in silence and the run still finished by saying everything passed.
            for (name, url) in fixtures.sorted(by: { $0.key < $1.key }) {
                check(
                    FileManager.default.fileExists(atPath: url.path),
                    "the fixture \(name) was built")
            }

            print("every disk on this Mac")
            surveyFlow()

            print("")
            print("encrypted container: \(container.lastPathComponent)")
            containerFlow(container: container, passphrase: passphrase)

            print("")
            print("the same container, opened read-only")
            readOnlyFlow(container: container, passphrase: passphrase)

            let encrypted = fixtures["qcow2-encrypted"]
            if let plain = fixtures["qcow2"], FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("qcow2, unencrypted: \(plain.lastPathComponent)")
                engineReadFlow(image: plain, passphrase: nil)
            }
            if let encrypted, FileManager.default.fileExists(atPath: encrypted.path) {
                print("")
                print("qcow2, encrypted: \(encrypted.lastPathComponent)")
                if EnginePaths.opensEncryptionInsideImages {
                    engineReadFlow(image: encrypted, passphrase: passphrase)
                } else {
                    engineReadRefusedFlow(image: encrypted)
                }
            }

            let vmdk = fixtures["vmdk"]
            let reaching = fixtures["vmdk-reaching"]
            if let vmdk, FileManager.default.fileExists(atPath: vmdk.path) {
                print("")
                print("VMDK: \(vmdk.lastPathComponent)")
                engineReadFlow(image: vmdk, passphrase: nil)
            }
            if let reaching, FileManager.default.fileExists(atPath: reaching.path) {
                print("")
                print("a VMDK reaching outside its folder: \(reaching.lastPathComponent)")
                hostileFlow(image: reaching)
            }

            let fixed = fixtures["vhd"]
            let dynamic = fixtures["vhd-dynamic"]
            if let fixed, FileManager.default.fileExists(atPath: fixed.path) {
                print("")
                print("fixed VHD: \(fixed.lastPathComponent)")
                engineReadFlow(image: fixed, passphrase: nil)
            }
            if let dynamic, FileManager.default.fileExists(atPath: dynamic.path) {
                print("")
                print("dynamic VHD: \(dynamic.lastPathComponent)")
                // Read by the engine's VHD driver. A build without it must say
                // so rather than serve the header as a disk.
                if EnginePaths.opensVdiAndVhd {
                    engineReadFlow(image: dynamic, passphrase: nil)
                } else {
                    refusedByNameFlow(image: dynamic, saying: "dynamic VHD")
                }
            }

            let vhdx = fixtures["vhdx"]
            let dirty = fixtures["vhdx-dirty"]
            let differencing = fixtures["vhdx-parent"]
            if let vhdx, FileManager.default.fileExists(atPath: vhdx.path) {
                print("")
                print("VHDX: \(vhdx.lastPathComponent)")
                if EnginePaths.opensVdiAndVhd {
                    engineReadFlow(image: vhdx, passphrase: nil)
                } else {
                    refusedByNameFlow(image: vhdx, saying: "VHDX")
                }
            }
            if let dirty, FileManager.default.fileExists(atPath: dirty.path) {
                print("")
                print("a VHDX that was not shut down cleanly: \(dirty.lastPathComponent)")
                refusedByNameFlow(image: dirty, saying: "not shut down cleanly")
            }
            if let differencing, FileManager.default.fileExists(atPath: differencing.path) {
                print("")
                print("a VHDX naming a parent disk: \(differencing.lastPathComponent)")
                refusedByNameFlow(image: differencing, saying: "another disk")
            }

            let sparse = fixtures["vmdk-sparse"]
            let streamed = fixtures["vmdk-streamed"]
            if let sparse, FileManager.default.fileExists(atPath: sparse.path) {
                print("")
                print("sparse VMDK: \(sparse.lastPathComponent)")
                if EnginePaths.opensSparseVmdk {
                    engineReadFlow(image: sparse, passphrase: nil)
                } else {
                    refusedByNameFlow(image: sparse, saying: "sparse VMDK")
                }
            }
            if let streamed, FileManager.default.fileExists(atPath: streamed.path) {
                print("")
                print("a VMDK whose grains are deflated: \(streamed.lastPathComponent)")
                if EnginePaths.opensSparseVmdk {
                    engineReadFlow(image: streamed, passphrase: nil)
                } else {
                    refusedByNameFlow(image: streamed, saying: "sparse VMDK")
                }
            }

            let vdi = fixtures["vdi"]
            let ancient = fixtures["vdi-ancient"]
            if let vdi, FileManager.default.fileExists(atPath: vdi.path) {
                print("")
                print("VDI: \(vdi.lastPathComponent)")
                if EnginePaths.opensVdiAndVhd {
                    engineReadFlow(image: vdi, passphrase: nil)
                } else {
                    refusedByNameFlow(image: vdi, saying: "VDI")
                }
            }
            if let ancient, FileManager.default.fileExists(atPath: ancient.path) {
                print("")
                print("a VDI written by a format nobody released: \(ancient.lastPathComponent)")
                refusedByNameFlow(image: ancient, saying: "not a disk image")
            }

            let hostile = fixtures["hostile"]
            if let hostile, FileManager.default.fileExists(atPath: hostile.path) {
                print("")
                print("an image naming another file: \(hostile.lastPathComponent)")
                hostileFlow(image: hostile)
            }

            print("")
            print("when things go wrong: \(container.lastPathComponent)")
            whenThingsGoWrongFlow(container: container, passphrase: passphrase)

            let exfat = fixtures["exfat"]
            if let exfat, FileManager.default.fileExists(atPath: exfat.path) {
                print("")
                print("exFAT image: \(exfat.lastPathComponent)")
                handOverFlow(image: exfat)
            }

            if let plain = fixtures["plain"], FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("unencrypted image: \(plain.lastPathComponent)")
                plainFlow(image: plain)
            }

            // Writing, for the formats whose drivers were written here. A file put
            // into a mounted image has to be in the image file afterwards, which no
            // amount of reading can demonstrate.
            //
            // Each is opened for writing and then opened again from scratch, so
            // what is checked is the file on disk rather than anything the first
            // mount still had in memory.
            let writable = [
                ("plain", "raw image"),
                ("vhd-dynamic", "dynamic VHD"),
                ("vhd", "fixed VHD"),
                ("vdi", "VDI"),
                ("vmdk-sparse", "sparse VMDK"),
                ("vmdk", "VMDK"),
                ("qcow2", "qcow2"),
            ]
            for (name, what) in writable {
                guard let image = fixtures[name],
                    FileManager.default.fileExists(atPath: image.path)
                else { continue }
                print("")
                print("writing to a \(what): \(image.lastPathComponent)")
                writeFlow(image: image)
            }

            // Writing through encryption: the same drivers underneath, with LUKS
            // between them and the filesystem. Nothing else here writes to a
            // volume that had to be unlocked first.
            for (name, what) in [("qcow2-encrypted", "qcow2"), ("container", "raw image")] {
                guard let image = fixtures[name],
                    FileManager.default.fileExists(atPath: image.path)
                else { continue }
                print("")
                print("writing to a LUKS volume inside a \(what): \(image.lastPathComponent)")
                writeFlow(image: image, passphrase: passphrase)
            }

            // Putting back what was open, which is what the setting at the top of
            // Settings does.
            if let plain = fixtures["plain"], FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("putting back what was open: \(plain.lastPathComponent)")
                restoreFlow(image: plain, passphrase: nil)
            }

            // And the two that are read and not written: asked for read-write,
            // each opens read-only rather than failing, and refuses to be written
            // to.
            for (name, what) in [("vhdx", "VHDX"), ("vmdk-streamed", "stream-optimized VMDK")] {
                guard let image = fixtures[name],
                    FileManager.default.fileExists(atPath: image.path), EnginePaths.opensVdiAndVhd
                else { continue }
                print("")
                print("writing to a \(what), which is read-only: \(image.lastPathComponent)")
                writeFlow(image: image, expectingReadOnly: true)
            }

            // Several at once, which is where the list itself is tested rather
            // than any one format: what arrives, what stays, what goes, and what a
            // passphrase is remembered against.
            let together = [
                ("a raw image", "plain"), ("a LUKS container", "container"),
                ("a VDI", "vdi"), ("a qcow2", "qcow2"),
            ].compactMap { what, name -> (String, URL)? in
                guard let url = fixtures[name], FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                return (what, url)
            }
            if together.count > 1 {
                print("")
                print(
                    "several images at once: \(together.map { $0.1.lastPathComponent }.joined(separator: ", "))"
                )
                manyFlow(together, passphrase: passphrase)
            }

            // Nothing stays attached, whatever the outcome. A run that failed
            // halfway left the image behind, and the next run then passed or failed
            // for reasons unrelated to the code.
            detachEverything(["container", "plain"].compactMap { fixtures[$0] })

            print("")
            print("\(checks - failures)/\(checks) steps passed")
            exit(failures > 0 ? 1 : 0)
        }

        // MARK: The flow

        /// Start the app, open an image, and find the row it became.
        ///
        /// Every flow below begins this way, and the steps that each flow exists
        /// for start a screen further down. Each wait is still checked here, so a
        /// preamble that fails is a counted failure and not a flow that quietly
        /// did nothing.
        @MainActor
        private static func openAndChoose(_ image: URL, timeout: TimeInterval = 60) -> (
            model: AppModel, drive: Drive
        )? {
            let model = AppModel()
            model.start()
            guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
                return nil
            }
            model.openImage(image)
            guard
                waitUntil(
                    "the image opens", timeout: timeout,
                    condition: {
                        model.imageOpening == nil
                            && model.drives.contains { $0.uuid == image.path }
                    })
            else {
                if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
                return nil
            }
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else {
                check(false, "the image appears in the list")
                return nil
            }
            return (model, drive)
        }

        @MainActor
        private static func containerFlow(container: URL, passphrase: String) {
            guard let (model, drive) = openAndChoose(container) else { return }
            check(
                drive.connection.contains(appString("Disk Image")), "it is listed as a disk image")

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
            check(
                before.isMounted && model.phase.isMounted, "and the screen is still the open drive")
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

        /// Several files open at once, and everything that can be done to them.
        ///
        /// Each of these was a report. Opening a second image made the first one
        /// vanish and come back somewhere else. Ejecting one drive detached an
        /// image that had nothing to do with it. Going back to the list opened a
        /// passphrase screen on its own. A saved passphrase came back for the
        /// wrong file, because what it was saved under was a device name that had
        /// since been handed to another image.
        ///
        /// So this opens them together and keeps them together: there is one list,
        /// rows arrive at the bottom, and what is done to one is done to none of
        /// the others.
        @MainActor
        private static func manyFlow(_ images: [(String, URL)], passphrase: String) {
            let model = AppModel()
            model.start()
            guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
                return
            }
            // Whatever is attached before the first file is opened. A physical
            // drive plugged into this Mac is one of these, and it must not move.
            let before = model.drives.map(\.uuid)

            var arrived: [String] = []
            for (what, url) in images {
                model.openImage(url)
                guard
                    waitUntil(
                        "\(what) opens", timeout: 120,
                        condition: {
                            model.imageOpening == nil
                                && model.drives.contains { $0.uuid == url.path }
                        })
                else {
                    if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
                    return
                }
                arrived.append(url.path)
                check(
                    model.drives.filter { arrived.contains($0.uuid) }.map(\.uuid) == arrived,
                    "and joins the list at the bottom, with the ones before it where they were")
                check(
                    before.allSatisfy { uuid in model.drives.contains { $0.uuid == uuid } },
                    "and nothing that was already there has gone")
                // Back to the list, as somebody who opened a file and then thought
                // better of it would.
                model.backToDrives()
            }

            // Nothing may put a passphrase screen up on its own. The reading of a
            // first sector answers in tens of milliseconds and its fallback fires
            // after a second and a half, so two seconds on the list is long enough
            // for anything left over to arrive.
            let settled = Date().addingTimeInterval(2)
            while Date() < settled {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            check(!model.phaseIsUnlock, "the list stays the list, and asks for nothing on its own")

            // A rebuild is the list being drawn again from scratch. Nothing about
            // it may move.
            let order = model.drives.map(\.uuid)
            let generation = model.scanGeneration
            model.refreshDrives()
            guard waitUntil("the list rebuilds", condition: { model.scanGeneration > generation })
            else { return }
            check(model.drives.map(\.uuid) == order, "and comes back in the same order, unchanged")

            // Two of them open at once: one that asks for nothing, and one that
            // asks for a passphrase and is told to remember it.
            guard let plain = images.first(where: { $0.0.contains("raw") })?.1,
                let locked = images.first(where: { $0.0.contains("LUKS") })?.1,
                let plainDrive = model.drives.first(where: { $0.uuid == plain.path }),
                let lockedDrive = model.drives.first(where: { $0.uuid == locked.path })
            else {
                check(false, "both the images this flow needs are listed")
                return
            }

            guard let plainPoint = open(model, plainDrive, credential: nil, remember: false) else {
                return
            }
            model.backToDrives()
            guard
                let lockedPoint = open(model, lockedDrive, credential: passphrase, remember: true)
            else { return }
            check(
                model.mountPoint(for: plainDrive) == plainPoint,
                "the first drive is still open while the second one opens")

            // The report: ejecting one took the other down with it.
            model.eject(lockedPoint)
            guard
                waitUntil("the second drive ejects", timeout: 120, condition: { !model.isEjecting })
            else { return }
            check(model.ejectProblem == nil, "and reports no problem")
            check(
                model.mountPoint(for: plainDrive) == plainPoint,
                "and the other drive is still open, which is the whole point")
            check(
                FileManager.default.fileExists(atPath: plainDrive.devicePath),
                "and its file is still attached")
            guard
                waitUntil(
                    "the ejected file is put back", timeout: 60,
                    condition: { !model.drives.contains { $0.uuid == locked.path } })
            else { return }

            // Opened again, from nothing. The passphrase was saved, so it is
            // offered -- and it has to be the one saved for this file rather than
            // for whatever last held its device name.
            model.openImage(locked)
            guard
                waitUntil(
                    "the file opens again", timeout: 120,
                    condition: {
                        model.imageOpening == nil
                            && model.drives.contains { $0.uuid == locked.path }
                    })
            else { return }
            guard let again = model.drives.first(where: { $0.uuid == locked.path }) else { return }
            model.backToDrives()
            model.choose(again)
            guard
                waitUntil(
                    "it is identified again", timeout: 60, condition: { model.chosenFormat != nil })
            else { return }
            check(model.credential == passphrase, "and its saved passphrase comes back with it")
            check(model.usingSavedCredential, "and says that is where it came from")

            // Forgotten, and it stays forgotten across an open and a close.
            model.forgetSavedCredential(for: again)
            check(model.credential.isEmpty, "forgetting it empties the field")
            model.backToDrives()
            model.choose(again)
            guard
                waitUntil(
                    "it is identified once more", timeout: 60,
                    condition: { model.chosenFormat != nil })
            else { return }
            check(model.credential.isEmpty, "and it is not offered again")
            check(!model.usingSavedCredential, "with nothing claiming to be saved")

            // And the drive that was never touched is still open through all of it.
            check(
                model.mountPoint(for: plainDrive) == plainPoint,
                "the drive nobody touched is still open at the end of it")
            model.eject(plainPoint)
            waitUntil("it ejects too", timeout: 120, condition: { !model.isEjecting })
        }

        /// Open one drive from the list and hand back where it landed.
        @MainActor
        private static func open(
            _ model: AppModel, _ drive: Drive, credential: String?, remember: Bool
        ) -> String? {
            model.choose(drive)
            guard
                waitUntil(
                    "\(drive.name) is identified", timeout: 60,
                    condition: { model.chosenFormat != nil })
            else { return nil }
            if let credential {
                model.credential = credential
                model.rememberCredential = remember
            }
            model.unlock(drive)
            guard
                waitUntil(
                    "\(drive.name) opens", timeout: 240,
                    condition: {
                        if case .mounted = model.phase { return true }
                        if case .failed = model.phase { return true }
                        return false
                    })
            else { return nil }
            guard case .mounted(_, let point) = model.phase else {
                check(false, "it opened rather than failing")
                return nil
            }
            return point
        }

        /// The same container, opened read-only.
        ///
        /// Asserted against the mount itself rather than against the flag that
        /// asked for it: a script that passed the flag and mounted the drive
        /// writable anyway would satisfy every check made in Swift.
        @MainActor
        private static func readOnlyFlow(container: URL, passphrase: String) {
            guard let (model, drive) = openAndChoose(container) else { return }

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
                guard waitUntil("the app finishes scanning", condition: { !model.isScanning })
                else {
                    return
                }
                model.openImage(image)
                guard
                    waitUntil(
                        "the image opens", timeout: 60,
                        condition: {
                            model.imageOpening == nil
                                && model.drives.contains { $0.uuid == image.path }
                        })
                else {
                    if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
                    return
                }
                guard let drive = model.drives.first(where: { $0.uuid == image.path }) else {
                    return
                }
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
                        "asked for read-write, it opened read-only, which is what this format allows"
                    )
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
            guard let (model, drive) = openAndChoose(image) else { return }
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
                guard let (model, drive) = openAndChoose(image) else { return }
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
            guard waitUntil("the app starts again", condition: { !model.isScanning }) else {
                return
            }
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
            guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
                return
            }
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
            check(
                model.phase.isMounted, "and it opened rather than complaining about the passphrase")
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
        private static func engineReadRefusedFlow(image: URL) {
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
        private static func engineReadFlow(image: URL, passphrase: String?) {
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
                check(
                    sawTheQuestion || model.phaseIsUnlock, "an encrypted one asks for a passphrase")
                check(
                    model.chosenFormat == .luks, "recognised as LUKS from the engine's own listing")
                model.credential = passphrase
                guard let drive = model.drives.first(where: { $0.uuid == image.path }) else {
                    return
                }
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
                guard let drive = model.drives.first(where: { $0.uuid == image.path }) else {
                    return
                }
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
            guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
                return
            }
            check(model.ejectProblem == nil, "ejecting reported no problem")
            waitUntil(
                "and it leaves the list", timeout: 30,
                condition: { !model.drives.contains { $0.uuid == image.path } })
        }

        /// The flows that do not succeed.
        ///
        /// Everything else here opens a drive and checks that it opened. What a
        /// person actually meets is a mistyped passphrase, a drive pulled out
        /// while it is being opened, a ceiling reached, and an eject that will
        /// not go through because something has a file open. Each of those has
        /// exactly one right behaviour, and none of them was checked anywhere.
        @MainActor
        private static func whenThingsGoWrongFlow(container: URL, passphrase: String) {
            // 1. A passphrase that is wrong.
            guard let (model, drive) = openAndChoose(container) else { return }
            model.choose(drive)
            guard
                waitUntil(
                    "it is identified", timeout: 30, condition: { model.chosenFormat != nil })
            else { return }

            model.credential = passphrase + "-wrong"
            model.unlock(drive)
            guard
                waitUntil(
                    "a wrong passphrase is refused", timeout: 180,
                    condition: {
                        if case .failed = model.phase { return true }
                        if case .mounted = model.phase { return true }
                        return false
                    })
            else { return }
            if case .mounted = model.phase {
                check(false, "a wrong passphrase is refused rather than opening the drive")
                return
            }
            guard case .failed(_, let summary, _) = model.phase else { return }
            check(!summary.isEmpty, "and the screen says why rather than going blank")
            check(
                model.chosenFormat == nil,
                "and what the drive holds is read again next time, not assumed")

            // 2. And the right one, straight afterwards, still works. A refusal
            //    that leaves the app unable to try again is worse than the
            //    refusal.
            model.choose(drive)
            guard
                waitUntil(
                    "it can be tried again", timeout: 30, condition: { model.chosenFormat != nil })
            else { return }
            model.credential = passphrase
            model.unlock(drive)
            guard
                waitUntil(
                    "the right passphrase then opens it", timeout: 180,
                    condition: {
                        if case .mounted = model.phase { return true }
                        if case .failed = model.phase { return true }
                        return false
                    })
            else { return }
            guard case .mounted(_, let mountPoint) = model.phase else {
                check(false, "the right passphrase then opens it")
                if case .failed(_, let why, let detail) = model.phase {
                    print("      \(why)")
                    if let detail { print("      \(detail.suffix(400))") }
                }
                return
            }

            // 3. An eject that cannot go through, because something is reading
            //    from the mount. It must be reported, and the drive must still
            //    be open afterwards rather than half gone.
            let held = URL(fileURLWithPath: mountPoint)
            let handle = try? FileHandle(forReadingFrom: held.appendingPathComponent("."))
            if handle != nil {
                // A directory handle is not enough to make NFS refuse on every
                // Mac, so this checks the reporting rather than forcing it.
                model.eject(mountPoint)
                _ = waitUntil("the eject finishes", timeout: 120, condition: { !model.isEjecting })
                let refused = model.ejectProblem != nil
                let gone = model.openMounts.isEmpty
                check(
                    refused != gone,
                    "an eject either completes or says why, and never both or neither")
                try? handle?.close()
            }
            if !model.openMounts.isEmpty {
                model.eject(mountPoint)
                _ = waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting })
            }
            check(model.openMounts.isEmpty, "and once nothing holds it, it ejects")

            // 4. The ceiling. Each open drive needs a loopback address of its
            //    own, and there is a fixed number of them: the app has to
            //    refuse rather than start a machine that cannot be served.
            //
            //    The limit cannot be lowered from in here -- Foundation reads
            //    the environment once, at launch, so LUKOTTA_CAPACITY only
            //    counts when it is set before the app starts. What is checked
            //    is therefore the wiring: that what the interface offers agrees
            //    with what the addresses on this Mac actually allow, with a
            //    drive open and again with none.
            let limited = AppModel()
            limited.start()
            guard waitUntil("the app finishes scanning", condition: { !limited.isScanning }) else {
                return
            }
            limited.openImage(container)
            guard
                waitUntil(
                    "one drive opens", timeout: 60,
                    condition: {
                        limited.imageOpening == nil
                            && limited.drives.contains { $0.uuid == container.path }
                    })
            else { return }
            guard let only = limited.drives.first(where: { $0.uuid == container.path }) else {
                return
            }
            limited.choose(only)
            guard
                waitUntil(
                    "it is identified", timeout: 60, condition: { limited.chosenFormat != nil })
            else { return }
            limited.credential = passphrase
            limited.unlock(only)
            guard
                waitUntil(
                    "it opens", timeout: 180,
                    condition: {
                        if case .mounted = limited.phase { return true }
                        if case .failed = limited.phase { return true }
                        return false
                    })
            else { return }
            guard case .mounted(_, let onlyMount) = limited.phase else { return }
            let withOneOpen = Capacity.now(mounts: limited.openMounts.count)
            check(
                limited.canOpenAnother
                    == Capacity.hasRoom(
                        limitCount: withOneOpen.limitCount, openCount: withOneOpen.openCount),
                "with a drive open, what is offered is what this Mac can serve")
            check(
                withOneOpen.openCount >= 1,
                "and the drive that is open is counted against the limit")

            limited.eject(onlyMount)
            _ = waitUntil("it ejects", timeout: 120, condition: { !limited.isEjecting })
            check(limited.canOpenAnother, "and ejecting one makes room again")
            check(
                Capacity.now(mounts: limited.openMounts.count).openCount == 0,
                "with nothing open, nothing is counted against it")

            // 5. A drive that goes away while it is being opened. Somebody
            //    pulls the cable, or the file is detached from underneath: the
            //    attempt has to end and say so, rather than sit on a screen
            //    that never changes.
            let vanishing = AppModel()
            vanishing.start()
            guard waitUntil("the app finishes scanning", condition: { !vanishing.isScanning })
            else { return }
            vanishing.openImage(container)
            guard
                waitUntil(
                    "a drive opens", timeout: 60,
                    condition: {
                        vanishing.imageOpening == nil
                            && vanishing.drives.contains { $0.uuid == container.path }
                    })
            else { return }
            guard let going = vanishing.drives.first(where: { $0.uuid == container.path }) else {
                return
            }
            vanishing.choose(going)
            guard
                waitUntil(
                    "it is identified", timeout: 30, condition: { vanishing.chosenFormat != nil })
            else { return }
            vanishing.credential = passphrase
            vanishing.unlock(going)
            // Detached from under the mount as it runs, which is exactly what
            // unplugging a drive does to the app.
            let device = DriveScanner.wholeDisk(of: going.id)
            Thread.sleep(forTimeInterval: 2)
            DiskImage.detach("/dev/" + device)
            let ended = waitUntil(
                "an attempt on a drive that goes away ends", timeout: 240,
                condition: {
                    if case .failed = vanishing.phase { return true }
                    if case .mounted = vanishing.phase { return true }
                    return false
                })
            check(ended, "and does not sit there for ever")
            if case .failed(_, let why, _) = vanishing.phase {
                check(!why.isEmpty, "with something said about why")
            }
            if case .mounted(_, let point) = vanishing.phase {
                // It got there first. Ejected, so nothing is left open.
                vanishing.eject(point)
                _ = waitUntil("it ejects", timeout: 120, condition: { !vanishing.isEjecting })
            }
            _ = EngineProcesses.tidyWhatServesNothing()
        }

        /// Every disk on this Mac, with a verdict each. Run against the real
        /// machine, so the result reflects what is plugged in.
        @MainActor
        private static func surveyFlow() {
            let model = AppModel()
            model.surveyDrives()
            guard
                waitUntil(
                    "every disk is surveyed", timeout: 30, condition: { !model.survey.isEmpty })
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
            let silent = model.survey.filter { $0.name.isEmpty || $0.content.isEmpty }
            check(silent.isEmpty, "and every row says what it is")
            // Which row, when there is one. A count says a row is empty; it does
            // not say which disk to go and look at.
            for row in silent {
                print("      \(row.id): name \"\(row.name)\", content \"\(row.content)\"")
            }
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

#endif
