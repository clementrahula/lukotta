// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

// Built into a pre-release and a local build, and out of the app people are
// given, like the other harnesses beside it.
#if DEVTOOLS

    import AppKit
    import LukottaCore

    /// Open and close a real drive from a shell, with no window and nobody
    /// clicking.
    ///
    ///     Lukotta --drive open=/dev/disk4s1
    ///     Lukotta --drive open=/dev/disk4s1 read-only
    ///     Lukotta --drive open=/dev/disk4s1 passphrase=secret
    ///     Lukotta --drive eject=/dev/disk4s1
    ///
    /// A physical drive's device node is `root:operator` mode 640 and the
    /// account running the tests is not in `operator`, so the engine cannot
    /// open one by itself: the running engine only has the device because the
    /// privileged daemon handed it over. The daemon checks its caller against a
    /// code requirement, so a separate command-line tool would have to be
    /// signed into the same family to ask -- and this application already is,
    /// because it is the application.
    ///
    /// Which is the whole reason this exists. Every measurement that needs a
    /// different machine -- another memory size, another thread count, another
    /// `before_mount` -- needs the drive closed and opened again, and doing
    /// that through the window means somebody sitting in front of it. Timing
    /// faults only appear on real hardware, and a run that needs a person is a
    /// run that happens once instead of twenty times.
    ///
    /// It goes through `AppModel`'s own route rather than a copy of it. A
    /// harness that mounts its own way tests its own way, and the fault being
    /// chased has twice turned out to be in the difference between two paths
    /// that were assumed to be one.
    ///
    /// Exits when the mount answers, before any scene is built, so nothing is
    /// drawn and nothing is left running.
    enum HeadlessDrive {

        @MainActor
        static func runIfAsked() {
            guard let index = CommandLine.arguments.firstIndex(of: "--drive") else { return }

            // A line at a time, because this is nearly always read from a file
            // or a pipe. C buffers a redirected stream in four-kilobyte blocks,
            // so everything said here sat unwritten until the process ended --
            // and a run that was killed for taking too long wrote nothing at
            // all. Every stalled run this morning produced an empty log and
            // looked like an app that had quietly done nothing, when it had in
            // fact been saying so the whole time.
            setvbuf(stdout, nil, _IOLBF, 0)
            setvbuf(stderr, nil, _IOLBF, 0)

            var toOpen: String?
            var toEject: String?
            var passphrase: String?
            var readOnly = false

            for argument in CommandLine.arguments.dropFirst(index + 1) {
                if argument == "read-only" { readOnly = true; continue }
                guard let equals = argument.firstIndex(of: "=") else { continue }
                let key = String(argument[argument.startIndex..<equals])
                let value = String(argument[argument.index(after: equals)...])
                switch key {
                case "open": toOpen = value
                case "eject": toEject = value
                case "passphrase": passphrase = value
                default: break
                }
            }

            // Print the guest actions the app would install, so a harness
            // driving the engine by hand installs exactly what the app does
            // rather than its own approximation of it.
            if CommandLine.arguments.contains("actions") {
                print(MountScript.microsoftActionsTOML)
                exit(0)
            }

            if let device = toEject { eject(device) }
            guard let device = toOpen else {
                if toEject != nil { exit(0) }
                say("usage: --drive open=/dev/diskNsM [read-only] [passphrase=…]")
                exit(2)
            }
            open(device, passphrase: passphrase, readOnly: readOnly)
        }

        /// What the daemon's job actually runs, as it appears in ps.
        ///
        /// Not the Mach service name, which is what this looked for first and
        /// which matches nothing: the job's BundleProgram is a path inside the
        /// bundle -- "Contents/MacOS/Lukotta<Brand>Helper" -- and that is the
        /// string a process listing shows. Looking for the wrong one found no
        /// daemon, decided nothing was stale, and let the run go ahead through
        /// the old one.
        private static func daemonProgram() -> String {
            let plist =
                Bundle.main.bundlePath
                + "/Contents/Library/LaunchDaemons/" + HelperInfo.plistName
            if let data = FileManager.default.contents(atPath: plist),
                let job = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
                let program = job["BundleProgram"] as? String
            {
                return program
            }
            return HelperInfo.machServiceName
        }

        /// The running daemon's process id, or nil if none is running.
        private static func daemonProcessID() -> Int32? {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-f", daemonProgram()]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n").compactMap {
                Int32($0.trimmingCharacters(in: .whitespaces))
            }.first
        }

        /// Whether the daemon running now started before the bundle's copy was
        /// last written, which is what "stale" means here.
        private static func daemonIsOlderThanTheBundle() -> Bool {
            let bundled = Bundle.main.bundlePath + "/" + daemonProgram()
            guard
                let written = (try? FileManager.default.attributesOfItem(atPath: bundled))?[
                    .modificationDate]
                    as? Date,
                let pid = daemonProcessID()
            else { return false }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-o", "etime=", "-p", "\(pid)"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let elapsed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let seconds = secondsIn(elapsed) else { return false }
            return Date().addingTimeInterval(-seconds) < written
        }

        /// ps prints elapsed time as [[dd-]hh:]mm:ss.
        private static func secondsIn(_ elapsed: String) -> TimeInterval? {
            var text = elapsed
            var days = 0.0
            if let dash = text.firstIndex(of: "-") {
                days = Double(text[text.startIndex..<dash]) ?? 0
                text = String(text[text.index(after: dash)...])
            }
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            let withinDay = parts.reduce(0.0) { $0 * 60 + $1 }
            return days * 86400 + withinDay
        }

        private static func say(_ line: String) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        /// The drive with this device path, as the app's own scan sees it.
        ///
        /// The scan lists physical disks unless it is told which attached
        /// images to include as well, and an image attached by hand is not a
        /// physical disk. Asking for a whole-disk container this way answered
        /// "no drive at /dev/disk7" -- for a container the window opens
        /// perfectly, because the window goes in by the image route and says
        /// which file it attached.
        ///
        /// The device asked for is the answer to that: whatever disk it belongs
        /// to is named, so an image is found by the same call that finds a
        /// stick, and a device that is neither is unaffected.
        @MainActor
        private static func find(_ device: String) -> Drive? {
            let identifier = (device as NSString).lastPathComponent
            let whole = DriveScanner.wholeDisk(of: identifier)
            return DriveScanner.scan(images: [whole]).first { $0.devicePath == device }
        }

        /// What the window would have found for this drive.
        ///
        /// The volume's own header first, then the partition UUID, in the same
        /// order and for the same reason as `AppModel.identity(of:)`.
        @MainActor
        private static func savedCredential(for drive: Drive) -> String? {
            var fingerprint: String?
            if let sector = BootSector.readWaiting(devicePath: drive.devicePath) {
                fingerprint = VolumeIdentity.fingerprint(
                    sector, format: BootSector.identify(sector))
            }
            let cache =
                UserDefaults.standard.dictionary(forKey: AppModel.fingerprintCacheKey)
                as? [String: String] ?? [:]
            let names = VolumeIdentity.names(
                fingerprint: fingerprint, uuid: drive.uuid, id: drive.id, cache: cache)
            for name in names {
                // Empty is not a passphrase, and saying it was one stopped the
                // search at a device node with nothing behind it.
                if let saved = CredentialStore.load(for: name), !saved.isEmpty {
                    say("using the key saved under \(name)")
                    return saved
                }
            }
            return nil
        }

        @MainActor
        private static func open(_ device: String, passphrase: String?, readOnly: Bool) {
            guard let drive = find(device) else {
                say("no drive at \(device)")
                exit(2)
            }
            say("\(drive.name) — \(drive.sizeDescription), \(drive.connection)")

            // The saved key is what the window would use; an empty one is
            // right for a volume that is not encrypted, and the engine says so
            // rather than this guessing from the partition type.
            //
            // Looked up the way the window looks it up. Asking by partition
            // UUID found nothing for the drives that have none -- every MBR
            // stick, and every locked BitLocker volume -- which is to say it
            // found nothing for exactly the drives a saved passphrase is for.
            let credential = passphrase ?? savedCredential(for: drive) ?? ""
            if credential.isEmpty {
                say("no passphrase given and none saved; opening as an unencrypted volume")
            }

            let helper = HelperClient()
            // The daemon answers launchd at once but the connection is made a
            // moment later. Waiting is not the same as assuming it is there:
            // an unready client returns nil from mount and that reads exactly
            // like a daemon that refused.
            let deadline = Date().addingTimeInterval(20)
            while !helper.isReady, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            guard helper.isReady else {
                say("the background daemon is not ready; a real drive cannot be opened without it")
                exit(3)
            }

            // The daemon is what builds the mount, and launchd keeps the
            // running one across an app update: the binary in the bundle is
            // replaced and the process is not. A measurement taken through a
            // daemon older than the change being measured is worse than no
            // measurement, because it looks like a result -- an afternoon went
            // into a run that was quietly using the previous script.
            //
            // So it is not asked for politely and hoped about. The daemon is
            // told to replace itself and this waits for the process to actually
            // change, and refuses to mount if it does not.
            // Ask, always. The daemon builds the mount, and launchd keeps the
            // running one across an app update: the binary in the bundle is
            // replaced and the process is not, so a rebuilt app goes on being
            // served by the daemon it was built to replace.
            //
            // This used to ask only when a time comparison here judged the
            // daemon older than the bundle. That comparison returned false on a
            // daemon twenty-three minutes older than a bundle written seconds
            // before, so the question was never put -- and raising the contract
            // did not help either, because nothing was asking. A check that
            // decides for itself whether to consult the real check is two
            // places to be wrong instead of one.
            //
            // So the app's own logic decides, on the contract it publishes and
            // the binaries it can compare, and this only watches for the result.
            // Waited for only when something was actually asked for.
            //
            // This used to wait for the process id to change whatever the
            // answer, and when the installed daemon already matches the bundle
            // nothing is asked, nothing changes, and the loop ran its whole
            // minute. Every open through --drive cost sixty seconds it had no
            // use for, which is most of the seventy-two that was briefly
            // written down as how long the app takes to open a drive. It takes
            // about ten.
            let before = daemonProcessID()
            var wasAsked: Bool?
            helper.replaceIfStale { wasAsked = $0 }
            let answerBy = Date().addingTimeInterval(20)
            while wasAsked == nil, Date() < answerBy {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            if wasAsked == true {
                let replaceBy = Date().addingTimeInterval(60)
                while daemonProcessID() == before, Date() < replaceBy {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
                }
            }
            if daemonProcessID() != before {
                say("the daemon was replaced; waiting for the new one")
                helper.refresh()
                let readyAgain = Date().addingTimeInterval(30)
                while !helper.isReady, Date() < readyAgain {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
                }
            }

            let workspace: Workspace
            do { workspace = try Workspace() } catch {
                say("no workspace: \(error)")
                exit(3)
            }
            let alias =
                (try? workspace.makeDeviceAlias(named: drive.name, target: drive.devicePath))?
                .path

            var answer: (status: Int32, transcript: String)??
            Task { @MainActor in
                answer = await helper.mount(
                    drive: drive, aliasPath: alias, volume: nil,
                    credential: credential, readOnly: readOnly)
            }
            while answer == nil {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }

            guard let outcome = answer ?? nil else {
                say("the daemon did not answer")
                exit(3)
            }
            // The transcript is the engine's own account, and it is the thing
            // worth having when a mount goes wrong at four in the morning.
            print(outcome.transcript)
            // And the volumes the check looked at are remembered here too.
            //
            // The windowed app records these as each line arrives, in
            // `AppModel.appendStatus`. This route never goes through it -- it
            // calls the helper and is handed the whole transcript at the end --
            // so on this path the record was never written. Every harness in
            // the gate opens drives this way, which means the rule those
            // records exist for was inert in exactly the runs that claim to
            // test it, and a full check would have run again on every open of a
            // volume nothing can repair.
            //
            // Before the status is looked at, deliberately: a volume the check
            // could not bring clean is precisely the one that must not be
            // scanned again, and it is the one whose mount fails.
            CheckedVolumes.note(
                reportedIn: outcome.transcript.components(separatedBy: .newlines))
            // A mount that serves nothing has not opened the drive.
            //
            // The engine can finish with status 0 having failed every one of
            // the additional NFS exports a container needs. Measured on
            // 2026-09-05, with the host's mount points still occupied by an
            // earlier run:
            //
            //     mount: /Volumes/disk5s1/FEDORAROOT: invalid file system.
            //     macOS: Failed to mount additional NFS exports: exit code 75
            //     mount script exited with status 0
            //     opened Disk Image
            //
            // Three volumes asked for, none served, and the word "opened".
            // Whatever the reason a mount fails, saying it worked is the one
            // answer that helps nobody: the drive is not in Finder and the app
            // has said it is.
            //
            // Asked of the mount table rather than of the transcript, because
            // the question is whether anything is actually being served -- and
            // that is the same question wherever the failure came from.
            let serving = MountTableEntry.all(in: LukottaCore.mountTable()).contains {
                $0.isEngineMount
                    && ($0.source.hasPrefix("\((drive.devicePath as NSString).lastPathComponent).")
                        || $0.source.contains(
                            "/run/\((drive.devicePath as NSString).lastPathComponent)/"))
            }
            if outcome.status == 0 && serving {
                say("opened \(drive.name)")
                exit(0)
            }
            if outcome.status == 0 {
                say("the drive did not open: the mount finished but nothing is served")
                exit(75)
            }
            say("the drive did not open (status \(outcome.status))")
            exit(Int32(truncatingIfNeeded: Int(outcome.status)))
        }

        /// Close whatever this device is serving.
        ///
        /// The mount goes and the engine follows: it watches its own share, and
        /// shuts the machine down once nothing is left to serve. That is how it
        /// ends when the volume is ejected in Finder, so it is how it ends here.
        @MainActor
        private static func eject(_ device: String) {
            // This device's mount, not every engine mount there is. With one
            // drive open the difference does not show; with a dozen -- which is
            // the thing the app claims and the thing being measured -- ejecting
            // one would have taken all of them down and called it a result.
            //
            // The engine names the share after the device it came from, so
            // "disk4s1.local:/mnt/LABEL" is how /dev/disk4s1 appears in the
            // table. Matched on that rather than on the label, which is the
            // volume's name and not the drive's.
            // A container's volumes are named after the group, not the device.
            //
            // Matching only "diskNsM." misses every logical volume of a LUKS or
            // LVM container: those come up as
            // "lvm-fedoravg.local:/run/diskNsM/FEDORAHOME", which starts with
            // the group's name. So this ejected nothing for a container and said
            // "nothing of /dev/diskNsM's is mounted" while three of its volumes
            // were served -- and since the helper made those mounts, nothing
            // short of root could then remove them. Measured on 2026-09-05: a
            // machine left with three of them, unremovable by the app that made
            // them, after the device they came from had been detached.
            //
            // The device is still in the export path, so that is what is
            // matched on. The windowed app has always found these -- it asks
            // EngineStatus for the volumes nested under the drive's own mount --
            // and this is the same set by a different road.
            let node = (device as NSString).lastPathComponent
            let table = LukottaCore.mountTable()
            let mine = MountTableEntry.all(in: table).filter {
                guard $0.isEngineMount else { return false }
                return $0.source.hasPrefix("\(node).") || $0.source.contains("/run/\(node)/")
            }
            if mine.isEmpty {
                say("nothing of \(device)'s is mounted")
                return
            }
            // Through the engine, not /sbin/umount.
            //
            // These mounts were made by the privileged helper, so unmounting one
            // as the user gets "Operation not permitted" -- and this said
            // "unmounted …" regardless, because it never looked at the exit
            // status. A machine was left on 2026-09-05 with three container
            // volumes that the app which made them could not remove, each line
            // of the eject claiming it had.
            //
            // EngineStatus.unmount is the same route the windowed app takes to
            // eject, and it reports whether it worked.
            for entry in mine {
                let result = EngineStatus.unmount(mountPoint: entry.mountPoint)
                if result.ok {
                    say("unmounted \(entry.mountPoint)")
                } else {
                    say("could not unmount \(entry.mountPoint): \(result.message)")
                }
            }
            // Give the engine the moment it takes to notice and stop.
            let deadline = Date().addingTimeInterval(30)
            while !EngineProcesses.running().isEmpty, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
            }
            // Not a ternary of two literals: the string extractor reads both
            // halves of one as text shown to somebody, and these are notes to
            // whoever is running the harness.
            if EngineProcesses.running().isEmpty {
                say("the machine has stopped")
            } else {
                say("the machine is still running")
            }
        }
    }

#endif
