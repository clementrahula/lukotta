// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

// The test harnesses are built into the pre-release and into a plain local
// build, and out of the app people are given: nobody running Lukotta has a use
// for a flag that renders every screen or opens every fixture, and what is not
// compiled in cannot be reached by passing one.
#if DEVTOOLS

    import AppKit
import CryptoKit
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
            // The volumes somebody built with make-test-volumes.sh have a
            // passphrase of their own, those images not being made here.
            var lvmPassphrase = ""
            for argument in CommandLine.arguments.dropFirst(index + 1) {
                guard let equals = argument.firstIndex(of: "=") else { continue }
                let key = String(argument[argument.startIndex..<equals])
                let value = String(argument[argument.index(after: equals)...])
                if key == "passphrase" {
                    passphrase = value
                } else if key == "lvm-passphrase" {
                    lvmPassphrase = value
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

            // A real Linux install's layout, when one has been built. Not made
            // here: scripts/make-test-volumes.sh builds these, and a Mac that
            // has never run it says so and carries on.
            if let group = fixtures["lvm"], FileManager.default.fileExists(atPath: group.path) {
                print("")
                print("a container holding several volumes: \(group.lastPathComponent)")
                severalVolumesFlow(
                    image: group,
                    passphrase: lvmPassphrase.isEmpty ? passphrase : lvmPassphrase)
            }

            if let plain = fixtures["plain"], FileManager.default.fileExists(atPath: plain.path) {
                print("")
                print("a machine that goes away without warning: \(plain.lastPathComponent)")
                unexpectedlyFlow(image: plain, passphrase: nil)
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
                // The filesystem the app exists for: what is inside a BitLocker
                // drive, and what every Windows disk is. Everything else here is
                // btrfs, so until this fixture existed nothing had written a
                // byte to NTFS except on the owner's own hardware.
                ("ntfs", "raw NTFS image"),
                // What nearly every Linux install puts on its volumes, and the
                // only filesystem here whose image is made on the Mac rather
                // than inside the guest -- there being no mkfs for it in there.
                ("ext4", "raw ext4 image"),
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
                writeFlow(image: image, fillingUp: name == "plain")
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
        /// - Parameter partitioned: the image carries a partition table, so the
        ///   list holds a row per partition and none of them is the file. Every
        ///   other fixture here is a bare container filling its image, whose
        ///   row is the file itself -- waiting for that row is what the volume
        ///   group image never satisfied, and three minutes of waiting said
        ///   "the image opens (gave up)" about an image that had opened.
        @MainActor
        private static func openAndChoose(
            _ image: URL, timeout: TimeInterval = 60, partitioned: Bool = false
        ) -> (model: AppModel, drive: Drive)? {
            guard !partitioned else { return openPartitioned(image, timeout: timeout) }
            return openWholeDisk(image, timeout: timeout)
        }

        /// A partitioned image: the app chooses the partition itself, as it does
        /// for somebody who opened the file from Finder.
        @MainActor
        private static func openPartitioned(_ image: URL, timeout: TimeInterval) -> (
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
                    condition: { model.imageOpening == nil && model.phaseIsUnlock })
            else {
                if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
                return nil
            }
            guard case .unlock(let drive) = model.phase else {
                check(false, "a volume of it is on screen")
                return nil
            }
            return (model, drive)
        }

        @MainActor
        private static func openWholeDisk(_ image: URL, timeout: TimeInterval) -> (
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
            // Against what was opened, not against itself. Comparing the list to
            // a copy of the list passes on an empty list, which is exactly the
            // case worth catching: everything opened here having quietly left it.
            check(
                arrived.allSatisfy { path in model.drives.contains { $0.uuid == path } },
                "and everything opened here is still in it")

            // Two of them open at once: one that asks for nothing, and one that
            // asks for a passphrase and is told to remember it.
            guard let plain = images.first(where: { $0.0.contains("raw") })?.1,
                let locked = images.first(where: { $0.0.contains("LUKS") })?.1,
                let plainDrive = model.drives.first(where: { $0.uuid == plain.path }),
                let lockedDrive = model.drives.first(where: { $0.uuid == locked.path })
            else {
                check(false, "both the images this flow needs are listed")
                print("      the list holds \(model.drives.count): "
                    + model.drives.map { ($0.uuid as NSString).lastPathComponent }
                        .joined(separator: ", "))
                for (what, url) in images where !model.drives.contains(where: { $0.uuid == url.path })
                {
                    print("      \(what) is not in it: \(url.lastPathComponent)")
                }
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

        /// What was written into a mounted drive, so that it can be asked for
        /// again after the machine that served it has gone.
        struct WrittenInEarnest {
            /// The digest of the large file, taken as it was written.
            var digest: String
            /// How many bytes that file was.
            var size: Int
            /// How many small files were written beside it.
            var count: Int
            /// The one that was overwritten after the fact, and what it should
            /// say now.
            var overwritten: String
            /// The names and shapes a filesystem is asked to carry besides
            /// bytes, and what each should read as.
            var awkward: [(what: String, name: String, contents: String)]
        }

        /// The name of the directory everything below is written into, so that
        /// what a run leaves behind can be taken away in one go.
        static let bulkDirectory = "lukotta-write-probe"

        /// Write enough to be worth reading back.
        ///
        /// One sentence in one file proves the write path exists and nothing
        /// else. What it never touches is the part of a container format that
        /// only appears once the file outgrows what was already allocated: a
        /// qcow2 or a dynamic VHD adds clusters as it goes and writes them
        /// wherever there is room, a VDI extends its block map, a sparse VMDK
        /// allocates grains. A driver that maps any of those wrongly returns
        /// somebody else's bytes, and a sixty-byte file lands inside the first
        /// cluster where nothing has to be mapped at all.
        ///
        /// So: thirty-two megabytes with a digest taken as it is written, two
        /// hundred small files in a directory of their own, one of them
        /// overwritten and one deleted. All of it read back after the drive has
        /// been ejected and opened again, which means a different machine
        /// reading the file as it now stands.
        @MainActor
        private static func writeInEarnest(at mountPoint: String) -> WrittenInEarnest? {
            let root = URL(fileURLWithPath: mountPoint)
                .appendingPathComponent(bulkDirectory, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                check(false, "a directory can be made on it (\(error.localizedDescription))")
                return nil
            }

            // Not zeroes and not random: a pattern that depends on where it is,
            // so a block returned from the wrong place reads as the wrong bytes
            // rather than as the same bytes.
            let size = 32 * 1024 * 1024
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<size {
                    base[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761)
                }
            }
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

            let large = root.appendingPathComponent("large.bin")
            let started = Date()
            do {
                try payload.write(to: large)
            } catch {
                check(false, "thirty-two megabytes can be written (\(error.localizedDescription))")
                return nil
            }
            let seconds = Date().timeIntervalSince(started)
            check(true, "thirty-two megabytes go in, at \(Int(Double(size) / 1_048_576 / max(seconds, 0.001))) MB/s")

            // A crowd of small files, which is metadata rather than data: the
            // part of a filesystem that a mount serving one file never touches.
            let many = root.appendingPathComponent("many", isDirectory: true)
            try? FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
            let count = 200
            var wrote = 0
            for index in 0..<count {
                let file = many.appendingPathComponent("file-\(index).txt")
                if (try? Data("file number \(index)\n".utf8).write(to: file)) != nil { wrote += 1 }
            }
            check(wrote == count, "and two hundred small files beside it (\(wrote) written)")

            // What a person does to a file they already have: change it, and
            // throw another away.
            let overwritten = "this file was written twice\n"
            let changed = many.appendingPathComponent("file-7.txt")
            let removed = many.appendingPathComponent("file-11.txt")
            let edited = (try? Data(overwritten.utf8).write(to: changed)) != nil
            let deleted = (try? FileManager.default.removeItem(at: removed)) != nil
            check(edited && deleted, "one of them is rewritten and another deleted")

            // Into the middle of what is already there, rather than on the end
            // of it. Appending only ever asks a container for the next block;
            // this asks it for a block it allocated a moment ago, at three
            // places it has to find rather than follow. A mapping that is
            // wrong by one cluster is invisible to a file written in one go
            // and obvious here.
            var expected = payload
            let patches: [(Int, UInt8)] = [
                (1 * 1024 * 1024, 0xA5), (17 * 1024 * 1024 + 4096, 0x5A),
                (size - 8192, 0xC3),
            ]
            var patched = true
            if let handle = try? FileHandle(forWritingTo: large) {
                for (offset, byte) in patches {
                    let block = Data(repeating: byte, count: 4096)
                    do {
                        try handle.seek(toOffset: UInt64(offset))
                        try handle.write(contentsOf: block)
                        expected.replaceSubrange(offset..<(offset + block.count), with: block)
                    } catch {
                        patched = false
                    }
                }
                try? handle.close()
            } else {
                patched = false
            }
            check(patched, "three blocks in the middle of it are written over")
            let digestAfter = SHA256.hash(data: expected).map { String(format: "%02x", $0) }
                .joined()

            let awkward = writeTheAwkwardThings(in: root)

            return WrittenInEarnest(
                digest: digestAfter, size: size, count: count, overwritten: overwritten,
                awkward: awkward)
        }

        /// The names and shapes a filesystem is asked to carry besides bytes.
        ///
        /// A volume that only ever holds "file-3.txt" is not a volume anybody
        /// keeps anything on. What people actually put on a drive is names in
        /// their own language, names as long as the filesystem allows, folders
        /// inside folders, links, and -- whether they want them or not -- the
        /// files Finder writes on every volume it opens.
        ///
        /// The accented ones matter more than they look. macOS hands out names
        /// decomposed, an e and an acute accent; Linux stores whatever bytes it
        /// is given. The engine mounts with `nfc`, which is what makes a name
        /// typed here come back the same, and nothing checked that it does.
        @MainActor
        private static func writeTheAwkwardThings(in root: URL)
            -> [(what: String, name: String, contents: String)]
        {
            let manager = FileManager.default
            let names = root.appendingPathComponent("names", isDirectory: true)
            try? manager.createDirectory(at: names, withIntermediateDirectories: true)

            // Every one of these is a name somebody has, or a name a filesystem
            // has a rule about.
            var written: [(what: String, name: String, contents: String)] = []
            let candidates: [(String, String)] = [
                ("an accented name", "Bänder für Käse.txt"),
                ("a name in Greek", "αντίγραφο ασφαλείας.txt"),
                ("a name in Japanese", "写真のバックアップ.txt"),
                ("a name in Arabic", "نسخة احتياطية.txt"),
                ("a name with an emoji", "holiday 🏖 2026.txt"),
                ("a name with spaces and quotes", "the \"good\" one - final (2).txt"),
                ("a name that starts with a dot", ".hidden-by-name"),
                ("a name as long as the filesystem allows", String(repeating: "n", count: 250) + ".txt"),
            ]
            for (what, name) in candidates {
                let file = names.appendingPathComponent(name)
                let contents = "this is \(what)\n"
                if (try? Data(contents.utf8).write(to: file)) != nil {
                    written.append((what, name, contents))
                } else {
                    check(false, "\(what) can be written")
                }
            }
            check(
                written.count == candidates.count,
                "eight names people actually use are written (\(written.count) of \(candidates.count))"
            )

            // Folders inside folders, which is a filesystem's other dimension.
            var deep = root.appendingPathComponent("deep", isDirectory: true)
            for level in 1...12 { deep = deep.appendingPathComponent("level-\(level)", isDirectory: true) }
            let buried = deep.appendingPathComponent("buried.txt")
            let madeDeep =
                (try? manager.createDirectory(at: deep, withIntermediateDirectories: true)) != nil
                && (try? Data("twelve deep\n".utf8).write(to: buried)) != nil
            check(madeDeep, "twelve folders inside each other, with a file at the bottom")

            // Links, both kinds.
            let target = names.appendingPathComponent(candidates[0].1)
            let symbolic = root.appendingPathComponent("a-symlink")
            let hard = root.appendingPathComponent("a-hard-link")
            _ = try? Data("#!/bin/sh\necho hello\n".utf8).write(
                to: root.appendingPathComponent("runnable.sh"))
            // Two symbolic links, because the difference between them is a
            // limitation worth pinning rather than meeting by accident.
            //
            // macOS is told to send names in composed form -- the `nfc` mount
            // option, which the engine sets on every mount and which is what
            // makes a name written on a Linux volume come back the way it was
            // typed. The same option makes the client refuse a symbolic link
            // whose target contains both a slash and a character outside ASCII:
            // symlink(2) answers EINVAL, and one that already exists cannot be
            // followed, though readlink still reads it back correctly.
            //
            // So an ASCII target works and an accented one does not, and both
            // are checked. A run where the accented one starts working is a run
            // that has found the option changed underneath it.
            let plainTarget = root.appendingPathComponent("runnable.sh")
            let simple = (try? manager.createSymbolicLink(
                at: symbolic, withDestinationURL: plainTarget)) != nil
            check(simple, "a symbolic link with an ordinary target is made")

            let awkwardLink = root.appendingPathComponent("a-symlink-to-an-accented-name")
            let refused = symlink(target.path, awkwardLink.path) != 0
            var whyRefused = "a target outside ASCII is refused, as the mount option requires"
            if !refused {
                whyRefused = "a target outside ASCII is refused (it was accepted this time)"
            } else if errno != EINVAL {
                whyRefused = "a target outside ASCII is refused, with errno \(errno)"
            }
            check(refused && errno == EINVAL, whyRefused)

            let madeHard = (try? manager.linkItem(at: target, to: hard)) != nil
            check(madeHard, "and a hard link, which has no such trouble")

            // What a program expects to be able to say about a file it wrote:
            // that it may be run, and when it was made.
            let script = root.appendingPathComponent("runnable.sh")
            let madeScript = (try? Data("#!/bin/sh\necho hello\n".utf8).write(to: script)) != nil
            let modeSet =
                (try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path))
                != nil
            check(madeScript && modeSet, "a file is marked executable")
            let stamped = Date(timeIntervalSince1970: 1_600_000_000)
            let dated =
                (try? manager.setAttributes([.modificationDate: stamped], ofItemAtPath: script.path))
                != nil
            check(dated, "and given a date of its own")

            // The three things Finder leaves on any volume it looks at, which
            // arrive whether or not anybody wanted them. AppleDouble carries
            // what the filesystem underneath cannot: an extended attribute on a
            // volume with nowhere to put one becomes a ._ file beside it.
            let finder = root.appendingPathComponent(".DS_Store")
            let double = root.appendingPathComponent("._a-file-with-a-fork")
            let forked = root.appendingPathComponent("a-file-with-a-fork")
            _ = try? Data(repeating: 0x07, count: 6148).write(to: finder)
            _ = try? Data(repeating: 0x00, count: 82).write(to: double)
            _ = try? Data("this one carries an attribute\n".utf8).write(to: forked)
            let attributed = forked.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                let value = Array("green".utf8)
                return setxattr(path, "com.apple.metadata:kMDItemFinderComment", value, value.count, 0, 0) == 0
            }
            check(
                manager.fileExists(atPath: finder.path) && manager.fileExists(atPath: double.path),
                "the files Finder writes on any volume it opens")
            check(attributed, "and an extended attribute on one of them")

            return written
        }

        /// Write until there is nowhere left to write, and see what that is like.
        ///
        /// Running out of room is not a fault, and it is the one failure a
        /// person is guaranteed to meet eventually. What matters is that it
        /// arrives as a refusal rather than as a truncated file, that it says
        /// so, and that the volume is still a volume afterwards -- the last
        /// being why this runs before everything written above is read back.
        @MainActor
        private static func fillItUp(at mountPoint: String) {
            let point = URL(fileURLWithPath: mountPoint)
            let free =
                (try? point.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity ?? 0
            guard free > 0 else {
                check(false, "the volume says how much room is left")
                return
            }

            let hog = point.appendingPathComponent("lukotta-fills-the-disk.bin")
            FileManager.default.createFile(atPath: hog.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: hog) else {
                check(false, "a file can be opened to fill it with")
                return
            }
            // Asked for more than there is, a piece at a time, so the refusal
            // arrives where a real one would: in the middle of a write.
            let piece = Data(repeating: 0x77, count: 4 * 1024 * 1024)
            var refused = false
            var wrote = 0
            while wrote < free + 16 * 1024 * 1024 {
                do {
                    try handle.write(contentsOf: piece)
                    wrote += piece.count
                } catch {
                    refused = true
                    break
                }
            }
            try? handle.close()
            check(refused, "filling the volume is refused rather than half-done")
            // Read as an answer or as nothing, never as zero: unreadable
            // attributes default to zero, and zero is under every limit, so the
            // check passed on a file nothing could measure.
            let onDisk = (try? FileManager.default.attributesOfItem(atPath: hog.path))?[.size]
                as? Int
            check(onDisk != nil, "and the file it half-wrote can be measured")
            check(
                (onDisk ?? Int.max) <= free + piece.count,
                "and what it holds is no more than there was room for")
            try? FileManager.default.removeItem(at: hog)
            let afterwards =
                (try? point.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity ?? 0
            check(afterwards > free / 2, "and the room comes back when it is deleted")
        }

        /// Ask for all of it back, from a machine that has never seen it.
        @MainActor
        private static func readItBack(_ written: WrittenInEarnest, at mountPoint: String) {
            let root = URL(fileURLWithPath: mountPoint)
                .appendingPathComponent(bulkDirectory, isDirectory: true)
            let large = root.appendingPathComponent("large.bin")

            // Read in pieces and digested as it comes, rather than held whole:
            // this is the read path a person's own copy takes.
            guard let handle = try? FileHandle(forReadingFrom: large) else {
                check(false, "the large file is still there")
                return
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            var read = 0
            while let piece = try? handle.read(upToCount: 4 * 1024 * 1024), !piece.isEmpty {
                hasher.update(data: piece)
                read += piece.count
            }
            check(read == written.size, "the large file is the size it was (\(read) bytes)")
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            check(digest == written.digest, "and every byte of it is what was written")

            let many = root.appendingPathComponent("many", isDirectory: true)
            let crowd = (try? FileManager.default.contentsOfDirectory(atPath: many.path)) ?? []
            check(
                crowd.count == written.count - 1,
                "the deleted file is gone and the rest are there (\(crowd.count) of \(written.count - 1))"
            )
            var wrong = 0
            for name in crowd {
                let index = name.replacingOccurrences(of: "file-", with: "")
                    .replacingOccurrences(of: ".txt", with: "")
                let expected =
                    index == "7" ? written.overwritten : "file number \(index)\n"
                let got = try? String(contentsOf: many.appendingPathComponent(name), encoding: .utf8)
                if got != expected { wrong += 1 }
            }
            check(wrong == 0, "and each of them says what it was last told to (\(wrong) wrong)")

            // The names, which is where a mount option rather than a driver
            // decides the answer. A name typed here as one character and stored
            // as two comes back as neither unless the mount composes it again.
            let names = root.appendingPathComponent("names", isDirectory: true)
            var missing: [String] = []
            for (what, name, contents) in written.awkward {
                let file = names.appendingPathComponent(name)
                let got = try? String(contentsOf: file, encoding: .utf8)
                if got != contents { missing.append(what) }
            }
            // Written as an if rather than a ternary on purpose: the string
            // extractor reads a literal in a ternary as a sentence the app
            // says, and the coverage gate then asks for it in thirty-six
            // languages.
            var nameVerdict = "every name comes back as it was typed"
            if !missing.isEmpty {
                nameVerdict += " (" + missing.joined(separator: ", ") + ")"
            }
            check(missing.isEmpty, nameVerdict)
            // Listed as well as opened: a name the mount hands back differently
            // from the one it was given opens by luck and lists wrongly.
            let listed = Set((try? FileManager.default.contentsOfDirectory(atPath: names.path)) ?? [])
            let expectedNames = Set(written.awkward.map(\.name))
            check(
                listed.isSuperset(of: expectedNames),
                "and the folder lists them under those names (\(listed.count) there)")

            let manager = FileManager.default
            let buried = (1...12).reduce(root.appendingPathComponent("deep", isDirectory: true)) {
                $0.appendingPathComponent("level-\($1)", isDirectory: true)
            }.appendingPathComponent("buried.txt")
            check(
                (try? String(contentsOf: buried, encoding: .utf8)) == "twelve deep\n",
                "the file twelve folders down is still there")

            let symbolic = root.appendingPathComponent("a-symlink")
            let hard = root.appendingPathComponent("a-hard-link")
            check(
                (try? manager.destinationOfSymbolicLink(atPath: symbolic.path)) != nil,
                "the symbolic link still points where it was pointed")
            check(
                (try? String(contentsOf: hard, encoding: .utf8))?.isEmpty == false,
                "and the hard link still reads as the file it was made from")

            let script = root.appendingPathComponent("runnable.sh")
            let attributes = try? manager.attributesOfItem(atPath: script.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            check(mode & 0o111 != 0, "what was marked executable still is")
            let modified = attributes?[.modificationDate] as? Date
            check(
                modified.map { abs($0.timeIntervalSince1970 - 1_600_000_000) < 2 } ?? false,
                "and the date it was given is the date it has")

            let forked = root.appendingPathComponent("a-file-with-a-fork")
            let attribute = forked.withUnsafeFileSystemRepresentation { path -> Int in
                guard let path else { return -1 }
                return getxattr(path, "com.apple.metadata:kMDItemFinderComment", nil, 0, 0, 0)
            }
            let double = root.appendingPathComponent("._a-file-with-a-fork")
            check(
                attribute > 0 || manager.fileExists(atPath: double.path),
                "the extended attribute survived, in one form or the other")
            check(
                manager.fileExists(atPath: root.appendingPathComponent(".DS_Store").path),
                "and what Finder wrote is where it left it")
        }

        /// Leave the fixture as it was found.
        @MainActor
        private static func removeWhatWasWritten(at mountPoint: String) {
            let root = URL(fileURLWithPath: mountPoint)
                .appendingPathComponent(bulkDirectory, isDirectory: true)
            try? FileManager.default.removeItem(at: root)
        }

        /// Write to an image, eject it, and open it again to see what stayed.
        ///
        /// The formats are written by drivers added here, so this is where their
        /// work meets a real filesystem: a file written through a mounted image has
        /// to survive the mount being torn down, the virtual machine exiting, and
        /// the image being opened again from the file on disk.
        @MainActor
        private static func writeFlow(
            image: URL, passphrase: String? = nil, expectingReadOnly: Bool = false,
            fillingUp: Bool = false
        ) {
            let contents = "written through \(image.lastPathComponent) at mount time\n"
            let name = "lukotta-write-probe.txt"

            // 1. Open it and write a file into it.
            var written = false
            var bulk: WrittenInEarnest?
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
                        "it mounts", timeout: 240,
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
                // Why, when it did not. A drive that quietly opens read-only is
                // the failure somebody meets at their first save, and "it was
                // read-only" says nothing about what to fix. The reason the app
                // shows, then the last of the engine's own steps.
                if model.mountedReadOnly {
                    print("      reason: \(model.readOnlyReason ?? "none given")")
                    print("      asked read-only: \(model.mountingReadOnly)")
                    for line in model.statusLines.suffix(25) { print("      \(line)") }
                }
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
                // Thirty-two megabytes, two hundred files and a volume filled
                // to its limit is what this is for, and it is not what every
                // caller wants: the update harness opens one drive to prove a
                // Mac with nothing on it can, and paid ten minutes for the rest.
                let thorough = ProcessInfo.processInfo.environment["LUKOTTA_E2E_QUICK"] != "1"
                if written, thorough { bulk = writeInEarnest(at: mountPoint) }
                if written, thorough, fillingUp { fillItUp(at: mountPoint) }

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
                    "it mounts again", timeout: 240,
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
            if let bulk { readItBack(bulk, at: mountPoint) }

            // Left as it was found, so the fixture can be used again.
            try? FileManager.default.removeItem(at: probe)
            if bulk != nil { removeWhatWasWritten(at: mountPoint) }
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
                    check(false, "it opened, rather than failing")
                    if case .failed(_, let summary, let detail) = model.phase {
                        print("      \(summary)")
                        if let detail, !detail.isEmpty { print("      \(detail)") }
                    }
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
                // Which is a question about this Mac as much as about the app:
                // an image already attached is handed back the device it has,
                // and nothing new is mounted.
                let devices = DiskImage.attachedDevices(forImages: [image.path])
                print("      attached as: \(devices.isEmpty ? "nothing" : devices.joined(separator: ", "))")
                let table = mountTable()
                for device in devices {
                    let mounted = MountTableEntry.all(in: table)
                        .filter { $0.source.hasPrefix(device) }
                        .map(\.mountPoint)
                    print("      \(device) is mounted at: \(mounted.isEmpty ? "nothing" : mounted.joined(separator: ", "))")
                }
                return
            }
            check(!sawTheQuestion, "and no password was ever asked for")
            check(model.chosenFormat == .exfat, "it was recognised as exFAT")

            // The volume must be local rather than served over NFS.
            check(FileManager.default.fileExists(atPath: point), "and macOS mounted it at \(point)")
            check(point.hasPrefix("/Volumes/"), "in /Volumes, like any other disk")
            check(
                !model.drives.contains { $0.uuid == image.path },
                "and it is not in this app's list, because it is not this app's to hold")

            // macOS owns the attachment once it is handed over. Detached by
            // the device it is actually on, which is what the image says: a
            // path built from the mount point names /dev/<volume name>, which
            // is nothing, and left the image attached after every run.
            for device in DiskImage.attachedDevices(forImages: [image.path]) {
                DiskImage.detach(device)
            }
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

        /// A container holding several volumes, each of them written to.
        ///
        /// The layout Ubuntu, Debian, Mint and Fedora all install: one LUKS
        /// container, one volume group, and root and home and sometimes backup
        /// inside it. The app serves them as one mount with the others nested
        /// underneath, which is a shape nothing else here has -- every fixture
        /// the harness builds for itself holds exactly one filesystem, so
        /// "several volumes" was tested by counting them and never by using
        /// them.
        @MainActor
        private static func severalVolumesFlow(image: URL, passphrase: String) {
            let name = "lukotta-volume-probe.txt"

            var points: [String] = []
            do {
                // Longer than the rest: this is the largest image the run
                // opens, and the engine reads a whole volume group out of it
                // before anything is shown. Sixty seconds is enough for a
                // single-filesystem fixture and was not for this.
                guard let (model, drive) = openAndChoose(image, timeout: 180, partitioned: true)
                else { return }
                guard
                    waitUntil(
                        "it is identified", timeout: 60,
                        condition: { model.phaseIsUnlock && model.chosenFormat != nil })
                else { return }
                model.credential = passphrase
                model.unlock(drive)
                guard
                    waitUntil(
                        "it mounts", timeout: 240,
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
                // Every volume it opened, which is the mount and whatever is
                // nested under it.
                _ = waitUntil(
                    "the volumes it holds are all mounted", timeout: 120,
                    condition: { model.openVolumes.count > 1 })
                points = model.openVolumes.isEmpty ? [mountPoint] : model.openVolumes
                check(points.count > 1, "more than one volume came up (\(points.count))")
                // What the app has, and what the system has, when those differ.
                print("      the app says: \(points.joined(separator: ", "))")
                print("      it counted: \(model.volumeCount)")
                let table = mountTable()
                let engineMounts = MountTableEntry.all(in: table)
                    .filter(\.isEngineMount).map(\.mountPoint)
                print("      engine mounts: \(engineMounts.joined(separator: ", "))")
                let underHome = MountTableEntry.all(in: table)
                    .filter { $0.mountPoint.contains("/Volumes/") }
                    .map { "\($0.source) on \($0.mountPoint)" }
                print("      anything under Volumes: \(underHome.joined(separator: " | "))")
                for line in model.statusLines.suffix(12) { print("      step: \(line)") }

                // Each file says which volume it is on, by that volume's own
                // name. Numbering them by position looked fine until they came
                // back in another order, and then two of the three were read
                // as the wrong file.
                var wrote = 0
                for point in points {
                    let probe = URL(fileURLWithPath: point).appendingPathComponent(name)
                    let contents = "this is \((point as NSString).lastPathComponent)\n"
                    do {
                        try Data(contents.utf8).write(to: probe)
                        wrote += 1
                    } catch {
                        print("      \(point): \(error.localizedDescription)")
                    }
                }
                check(wrote == points.count, "each of them takes a file (\(wrote) of \(points.count))")
                check(
                    !model.mountedReadOnly,
                    "and the group opened read-write, nobody having asked otherwise")

                model.eject(mountPoint)
                _ = waitUntil("they all eject together", timeout: 180, condition: { !model.isEjecting })
                check(model.ejectProblem == nil, "ejecting reported no problem")
            }

            // Opened again, by a machine that has never seen any of them.
            guard let (model, drive) = openAndChoose(image, timeout: 180, partitioned: true)
            else { return }
            guard
                waitUntil(
                    "it is identified again", timeout: 60,
                    condition: { model.phaseIsUnlock && model.chosenFormat != nil })
            else { return }
            model.credential = passphrase
            model.unlock(drive)
            guard
                waitUntil(
                    "and mounts again", timeout: 240,
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
            _ = waitUntil(
                "the volumes come back", timeout: 120,
                condition: { model.openVolumes.count >= points.count })
            let now = model.openVolumes.isEmpty ? [mountPoint] : model.openVolumes
            var found = 0
            for point in now {
                let probe = URL(fileURLWithPath: point).appendingPathComponent(name)
                let expected = "this is \((point as NSString).lastPathComponent)\n"
                if (try? String(contentsOf: probe, encoding: .utf8)) == expected { found += 1 }
                try? FileManager.default.removeItem(at: probe)
            }
            check(
                found == points.count,
                "what was written to each volume is in each volume (\(found) of \(points.count))")

            model.eject(mountPoint)
            _ = waitUntil("they eject again", timeout: 180, condition: { !model.isEjecting })
        }

        /// What happens when the drive does not go away politely.
        ///
        /// Two ways it does not, both of them ordinary. Somebody force-quits
        /// the app, or it crashes, and the machine serving the volume goes with
        /// nothing unmounted. Or somebody ejects the volume in Finder, which
        /// this app is not told about and only finds out by looking.
        ///
        /// What matters after either is the same: what was written is on the
        /// drive, and the app is not left holding a mount that is not there.
        @MainActor
        private static func unexpectedlyFlow(image: URL, passphrase: String?) {
            let marker = "written just before the machine was taken away\n"
            let name = "lukotta-crash-probe.txt"

            // 1. Open it, write something, and take the machine down where it
            //    stands -- which is what a crash looks like from the volume's
            //    side: no unmount, no flush, no eject.
            do {
                guard let (model, drive) = openAndChoose(image) else { return }
                guard
                    waitUntil(
                        "it is identified", timeout: 60,
                        condition: { model.phaseIsUnlock && model.chosenFormat != nil })
                else { return }
                if let passphrase { model.credential = passphrase }
                model.unlock(drive)
                guard
                    waitUntil(
                        "it mounts", timeout: 240,
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
                let wrote = (try? Data(marker.utf8).write(to: probe)) != nil
                check(wrote, "something is written to it")
                guard wrote else { return }

                EngineProcesses.stop(EngineProcesses.running())
                check(true, "and the machine serving it is taken away without an eject")
                _ = waitUntil(
                    "the mount goes with it", timeout: 120,
                    condition: { !FileManager.default.fileExists(atPath: mountPoint + "/" + name) })
            }

            // 2. Open it again. Nothing about the first mount was tidy, and
            //    what was written still has to be there.
            do {
                guard let (model, drive) = openAndChoose(image) else { return }
                guard
                    waitUntil(
                        "it opens again after that", timeout: 60,
                        condition: { model.phaseIsUnlock && model.chosenFormat != nil })
                else { return }
                if let passphrase { model.credential = passphrase }
                model.unlock(drive)
                guard
                    waitUntil(
                        "and mounts", timeout: 180,
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
                let probe = URL(fileURLWithPath: mountPoint).appendingPathComponent(name)
                let read = try? String(contentsOf: probe, encoding: .utf8)
                check(read == marker, "what was written before the crash is on the drive")
                try? FileManager.default.removeItem(at: probe)

                // 3. And now the other way: ejected in Finder, behind this
                //    app's back. Nothing tells it; it has to notice.
                _ = shellOutput("/sbin/umount", ["-f", mountPoint])
                let noticed = waitUntil(
                    "ejected in Finder, the app notices it has gone", timeout: 120,
                    condition: {
                        model.refreshDrives()
                        return model.openMounts.values.contains(mountPoint) == false
                    })
                check(noticed, "and stops offering to eject a drive that is not there")
                // Still remembered, and that is the decision rather than an
                // oversight: a mount can go without an eject because somebody
                // ejected it in Finder, or because a cable moved, or because
                // the Mac slept, and the mount table says which of those it was
                // in none of the three cases. AppModel.dropMounts says so in as
                // many words. Pinned here so that changing it is deliberate.
                let remembered = MountMemory.all().contains { (entry: MountMemory.Entry) in
                    entry.imagePath == image.path
                }
                check(
                    remembered,
                    "and still means to put it back, a mount going away not being an eject")
            }
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
