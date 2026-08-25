// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

#if DEVTOOLS

    import AppKit
    import LukottaCore
    import Sparkle

    /// Applying a real update, with nobody at the keyboard.
    ///
    /// An update is the one thing this app does that cannot be undone by trying
    /// again: it replaces the running application, and a version that will not
    /// start takes the working one with it. It is also the flow least likely to
    /// be exercised before release, because exercising it by hand means cutting
    /// a release first.
    ///
    /// So it is driven here instead. Sparkle's own updater, its own appcast, its
    /// own signature checks, the real archive over a real HTTP connection to
    /// this Mac -- everything except the person clicking Install. Nothing is
    /// simulated: what this proves is what a person's Mac will do.
    ///
    /// Compiled out of the released app.
    @MainActor
    enum UpdateHarness {

        /// `--update-test <feed-url>`: check that feed, take whatever it offers,
        /// install it and relaunch. Exits 0 once the new version is running.
        static func runIfAsked() {
            guard let index = CommandLine.arguments.firstIndex(of: "--update-test") else { return }
            guard CommandLine.arguments.count > index + 1 else {
                FileHandle.standardError.write(Data("usage: --update-test <feed-url>\n".utf8))
                exit(2)
            }
            let feed = CommandLine.arguments[index + 1]
            say("checking \(feed)")

            let driver = HeadlessDriver()
            // Installed, not relaunched. A relaunch would leave a window open
            // on the Mac this was run from, and what is being proved is that
            // the bundle in /Applications is replaced by one that starts --
            // which the script checks for itself, by asking it to.
            let delegate = HeadlessDelegate()
            Self.delegate = delegate

            // A drive open while the update arrives, when one was asked for.
            //
            // The app postpones an update it would have to interrupt: without
            // the helper the virtual machine serving the drive is this
            // process's own child, so replacing the bundle takes the drive with
            // it. That is written down in UpdaterRelay and had never once been
            // run -- and an engine running out of a bundle Sparkle is replacing
            // is exactly what wedged an earlier run of this harness.
            if let held = value(after: "hold") {
                holdOpen(URL(fileURLWithPath: held), passphrase: value(after: "with"))
            }
            let updater = SPUUpdater(
                hostBundle: Bundle.main, applicationBundle: Bundle.main,
                userDriver: driver, delegate: delegate)
            do {
                try updater.start()
            } catch {
                fail("the updater would not start: \(error.localizedDescription)")
            }
            updater.updateCheckInterval = 3600
            updater.automaticallyChecksForUpdates = false
            updater.setFeedURL(URL(string: feed))
            updater.checkForUpdates()

            // Sparkle needs the run loop; the driver exits the process when it
            // is done, one way or the other.
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline, RunLoop.current.run(mode: .default, before: .distantFuture) {}
            fail("nothing happened within five minutes")
        }

        /// Held here because the updater keeps only a weak reference to it.
        static var delegate: (any SPUUpdaterDelegate)?

        /// The drive being held open while the update is offered, if any.
        static var holding: (model: AppModel, mountPoint: String)?

        /// The value of `name=value` on the command line, or nil.
        static func value(after name: String) -> String? {
            for argument in CommandLine.arguments where argument.hasPrefix(name + "=") {
                return String(argument.dropFirst(name.count + 1))
            }
            return nil
        }

        /// Open an image and leave it mounted, so the update arrives while a
        /// drive is open.
        @MainActor
        static func holdOpen(_ image: URL, passphrase: String?) {
            let model = AppModel()
            model.start()
            let ready = Date().addingTimeInterval(60)
            while model.isScanning, Date() < ready {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            model.openImage(image)
            let opened = Date().addingTimeInterval(120)
            while model.imageOpening != nil || !model.drives.contains(where: { $0.uuid == image.path }
            ), Date() < opened {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            guard let drive = model.drives.first(where: { $0.uuid == image.path }) else {
                fail("the drive to hold open would not open: \(image.lastPathComponent)")
            }
            model.choose(drive)
            let identified = Date().addingTimeInterval(60)
            while model.chosenFormat == nil, Date() < identified {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if let passphrase { model.credential = passphrase }
            model.unlock(drive)
            let mounted = Date().addingTimeInterval(240)
            var point: String?
            while point == nil, Date() < mounted {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                if case .mounted(_, let where_) = model.phase { point = where_ }
                if case .failed(_, let why, _) = model.phase { fail("it would not mount: \(why)") }
            }
            guard let point else { fail("it did not mount inside four minutes") }
            holding = (model, point)
            say("holding \(image.lastPathComponent) open at \(point)")
        }

        static func say(_ what: String) {
            FileHandle.standardOutput.write(Data("  \(what)\n".utf8))
        }

        static func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("  FAIL \(why)\n".utf8))
            exit(1)
        }
    }

    /// Refuses the relaunch, and does what the app's own delegate does.
    ///
    /// The app keeps the outgoing bundle aside from Sparkle's willInstallUpdate,
    /// which is the last moment it can: that call arrives in the version about
    /// to be replaced. A harness with a delegate of its own does not get that
    /// call unless it implements it -- so it did not, nothing was kept, and the
    /// rollback the whole thing exists to prove had nothing to roll back to.
    /// The check said so and was read as a fault in the app.
    private final class HeadlessDelegate: NSObject, SPUUpdaterDelegate {
        // Every hook between "there is an update" and "the bundle has been
        // replaced", so a run says which of them arrive. The app keeps the
        // outgoing version aside from one of these, and a hook that is never
        // called is a safety net that is never armed.
        func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
            UpdateHarness.say("hook: the feed was read")
        }

        func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
            UpdateHarness.say("hook: downloaded")
            Rollback.keepCurrentAside()
        }

        func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
            UpdateHarness.say("hook: unpacked")
            Rollback.keepCurrentAside()
        }

        func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            UpdateHarness.say("hook: about to relaunch")
        }

        func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            Rollback.keepCurrentAside()
            UpdateHarness.say("keeping this version aside first")
            // Then quit, which is what the installer is waiting for. Quitting on
            // a timer instead arrives before this callback and keeps nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }

        /// Relaunched only where the run is about postponing one.
        ///
        /// Sparkle asks whether to put the install off only when it means to
        /// relaunch afterwards, so refusing the relaunch refuses the question
        /// -- and the check that an update waits for an open drive passed
        /// through a code path that was never asked anything.
        func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
            CommandLine.arguments.contains { $0.hasPrefix("hold=") }
        }

        /// The app's rule, asked of the app's own relay: an update is put off
        /// while this process is the one serving the drive.
        func updater(
            _ updater: SPUUpdater,
            shouldPostponeRelaunchForUpdate item: SUAppcastItem,
            untilInvokingBlock installHandler: @escaping () -> Void
        ) -> Bool {
            let held = MainActor.assumeIsolated { UpdateHarness.holding }
            guard let held else { return false }
            UpdateHarness.say("postponed, because a drive is open")

            // Ejected the way somebody would, and then the update goes ahead.
            // What is being proved is that it waited: an update that replaced
            // the bundle now would take the machine serving that drive with it.
            MainActor.assumeIsolated {
                held.model.eject(held.mountPoint)
                UpdateHarness.holding = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                UpdateHarness.say("the drive is ejected; letting it install")
                installHandler()
            }
            return true
        }
    }

    /// Every decision a person would make, made the same way every time: yes.
    ///
    /// The point is not to test the questions -- it is to reach the parts after
    /// them, which are where an update actually goes wrong: the signature, the
    /// extraction, the swap, and whether what comes back up runs.
    private final class HeadlessDriver: NSObject, SPUUserDriver {

        func show(
            _ request: SPUUpdatePermissionRequest,
            reply: @escaping (SUUpdatePermissionResponse) -> Void
        ) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }

        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

        func showUpdateFound(
            with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
            reply: @escaping (SPUUserUpdateChoice) -> Void
        ) {
            UpdateHarness.say(
                "offered \(appcastItem.displayVersionString) (build \(appcastItem.versionString))")
            reply(.install)
        }

        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

        func showUpdateNotFoundWithError(
            _ error: any Error, acknowledgement: @escaping () -> Void
        ) {
            UpdateHarness.fail("the feed offered nothing: \(error.localizedDescription)")
        }

        func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
            UpdateHarness.fail(error.localizedDescription)
        }

        func showDownloadInitiated(cancellation: @escaping () -> Void) {
            UpdateHarness.say("downloading")
        }

        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

        func showDownloadDidReceiveData(ofLength length: UInt64) {}

        func showDownloadDidStartExtractingUpdate() {
            UpdateHarness.say("unpacking")
        }

        func showExtractionReceivedProgress(_ progress: Double) {}

        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            UpdateHarness.say("installing")
            reply(.install)

            // Sparkle asks an application to quit by asking AppKit to, and this
            // one runs no event loop for AppKit to ask through, so the request
            // reaches nobody and the installer waits for a process that will
            // never leave.
            //
            // The quitting happens a callback later, in willInstallUpdate,
            // where the outgoing version is kept aside first. This is the
            // backstop for an update that never reaches it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                UpdateHarness.say("quitting without being told to keep anything aside")
                exit(0)
            }
        }

        func showInstallingUpdate(
            withApplicationTerminated applicationTerminated: Bool,
            retryTerminatingApplication: @escaping () -> Void
        ) {
            guard applicationTerminated else {
                // The installer will not replace a bundle while the application
                // inside it is running, so quitting is the whole of what there
                // is to do here. Waiting instead means both sides wait.
                UpdateHarness.say("quitting, so the bundle can be replaced")
                exit(0)
            }
        }

        func showUpdateInstalledAndRelaunched(
            _ relaunched: Bool, acknowledgement: @escaping () -> Void
        ) {
            var what = "installed"
            if relaunched { what += " and relaunched" }
            UpdateHarness.say(what)
            acknowledgement()
            exit(0)
        }

        func dismissUpdateInstallation() {}
    }

#endif
