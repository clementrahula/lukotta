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

            if let device = toEject { eject(device) }
            guard let device = toOpen else {
                if toEject != nil { exit(0) }
                say("usage: --drive open=/dev/diskNsM [read-only] [passphrase=…]")
                exit(2)
            }
            open(device, passphrase: passphrase, readOnly: readOnly)
        }

        private static func say(_ line: String) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        /// The drive with this device path, as the app's own scan sees it.
        @MainActor
        private static func find(_ device: String) -> Drive? {
            DriveScanner.scan().first { $0.devicePath == device }
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
            let credential = passphrase ?? CredentialStore.load(for: drive.uuid) ?? ""
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
            if outcome.status == 0 {
                say("opened \(drive.name)")
                exit(0)
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
            let table = LukottaCore.mountTable()
            let mine = MountTableEntry.all(in: table).filter(\.isEngineMount)
            for entry in mine {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/sbin/umount")
                task.arguments = ["-f", entry.mountPoint]
                try? task.run()
                task.waitUntilExit()
                say("unmounted \(entry.mountPoint)")
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
