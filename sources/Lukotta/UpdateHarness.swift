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
        func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            Rollback.keepCurrentAside()
            UpdateHarness.say("keeping this version aside first")
        }

        func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
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

            // And then quit, which is the only thing left for an application to
            // do. By now the installer is running in a process of its own and
            // waiting for this one to leave before it replaces the bundle it is
            // sitting in.
            //
            // Sparkle asks an application to quit by asking AppKit to, and this
            // one has no event loop for AppKit to ask through -- so the request
            // arrived nowhere, the installer waited, and the run failed five
            // minutes later with the update built, downloaded, verified and not
            // installed. Killing the process by hand finished it in seconds,
            // which is how this was found the first time and the second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                UpdateHarness.say("quitting, so the bundle can be replaced")
                exit(0)
            }
        }

        func showInstallingUpdate(
            withApplicationTerminated applicationTerminated: Bool,
            retryTerminatingApplication: @escaping () -> Void
        ) {
            guard applicationTerminated else {
                // Quitting is the whole of what an application does here.
                // The installer will not replace a bundle while the
                // application inside it is running, so it waits -- and this
                // used to wait back, sitting in its run loop believing it
                // would go away by itself. The two waited for each other
                // until the harness gave up five minutes later. Killing the
                // process by hand finished the update in seconds, which is
                // what said which of them was wrong.
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
