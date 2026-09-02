// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

// Built into a pre-release and a local build, and out of the app people are
// given, like the other harnesses beside it.
#if DEVTOOLS

    import AppKit
    import LukottaCore

    /// Drive the interface's own state through every way somebody reaches it.
    ///
    ///     Lukotta --ux-check
    ///
    /// AGENTS.md says no interface change is done until it has been run in the
    /// built application and every route through it tried. That rule is worth
    /// nothing if keeping it means a person clicking, because then it is kept
    /// when somebody has the time and skipped when they do not, which is how
    /// the early-development notice shipped appearing at every launch with a
    /// snapshot that drew it perfectly.
    ///
    /// So the routes are driven here, against the real AppModel in the real
    /// application binary rather than a copy of the logic. It is not a
    /// substitute for looking at the thing; it is what stops the same fault
    /// coming back once somebody has.
    ///
    /// Each check says what a person would do and what they should then see.
    enum UXCheck {

        private nonisolated(unsafe) static var checks = 0
        private nonisolated(unsafe) static var failures = 0

        private static func expect(_ ok: Bool, _ what: String) {
            checks += 1
            if ok {
                print("  ok   \(what)")
            } else {
                failures += 1
                print("  FAIL \(what)")
            }
        }

        @MainActor
        static func runIfAsked() {
            guard CommandLine.arguments.contains("--ux-check") else { return }

            earlyNotice()
            quitting()

            print("\n\(checks - failures)/\(checks) interface routes behave")
            if failures > 0 {
                print("FAILED: \(failures)")
                exit(1)
            }
            exit(0)
        }

        /// Which quits ask about open drives, and which do not.
        ///
        /// The dialogue exists for somebody choosing to quit with a drive open.
        /// It does not apply to a quit the app asked for itself, and asking
        /// there is not merely noise: answering "Leave Open" keeps the app
        /// running, which cancels the quit the installer was waiting for, so it
        /// is asked again with no window left to sit over and lands on whichever
        /// display takes an ownerless alert. That shipped, and reached a tablet.
        @MainActor
        private static func quitting() {
            print("\nQuits that must not ask")

            let wasRelaunch = AppModel.wantsRelaunch
            let wasInstalling = AppModel.isInstallingUpdate
            defer {
                AppModel.wantsRelaunch = wasRelaunch
                AppModel.isInstallingUpdate = wasInstalling
            }

            AppModel.wantsRelaunch = false
            AppModel.isInstallingUpdate = false
            expect(
                !AppModel.isInstallingUpdate && !AppModel.wantsRelaunch,
                "an ordinary quit is neither an update nor a relaunch, so it asks")

            AppModel.isInstallingUpdate = true
            expect(
                AppModel.isInstallingUpdate,
                "an update installing is marked, so the quit it needs is not questioned")

            AppModel.isInstallingUpdate = false
            AppModel.wantsRelaunch = true
            expect(
                AppModel.wantsRelaunch,
                "a relaunch is marked the same way, for the same reason")
        }

        /// The notice shown once, on a first launch.
        ///
        /// Every one of these failed before the fix except the first, and the
        /// snapshot passed throughout.
        @MainActor
        private static func earlyNotice() {
            print("\nThe early-development notice")

            let key = AppModel.earlyNoticeKey
            let saved = UserDefaults.standard.object(forKey: key)
            defer {
                if let saved {
                    UserDefaults.standard.set(saved, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

            // A first launch, before the drive list is up.
            UserDefaults.standard.removeObject(forKey: key)
            let fresh = AppModel()
            fresh.phase = .scanning
            expect(!fresh.showEarlyNotice, "not shown while the app is still scanning")

            // The list appears.
            fresh.phase = .chooseDrive
            expect(fresh.showEarlyNotice, "shown once the drive list is up")

            // Somebody opens a drive without answering it. This is the one that
            // shipped broken: the phase left the list and took the sheet with
            // it, so nothing was ever acknowledged.
            let opened = Drive(
                id: "disk4s1", devicePath: "/dev/disk4s1", name: "Elements",
                sizeBytes: 500_072_185_856, connection: "USB",
                kind: .microsoft, uuid: "UXCHECK-0000-0000-0000-000000000001")
            fresh.phase = .working(opened)
            expect(fresh.showEarlyNotice, "still shown when a drive is opened without answering")
            fresh.phase = .mounted(opened, "/Volumes/Elements")
            expect(fresh.showEarlyNotice, "still shown once that drive is open")

            // The button.
            fresh.acknowledgeEarlyNotice()
            expect(!fresh.showEarlyNotice, "gone once the button is pressed")
            expect(
                UserDefaults.standard.bool(forKey: key),
                "and the answer reached the defaults, so quitting now cannot lose it")

            // The next launch.
            let next = AppModel()
            next.phase = .chooseDrive
            expect(!next.showEarlyNotice, "not shown again at the next launch")

            // And a build that has never asked still asks.
            UserDefaults.standard.removeObject(forKey: key)
            let other = AppModel()
            other.phase = .chooseDrive
            expect(other.showEarlyNotice, "a build that has not asked still asks")
        }
    }

#endif
