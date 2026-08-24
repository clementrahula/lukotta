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
            let updater = SPUUpdater(
                hostBundle: Bundle.main, applicationBundle: Bundle.main,
                userDriver: driver, delegate: nil)
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

        static func say(_ what: String) {
            FileHandle.standardOutput.write(Data("  \(what)\n".utf8))
        }

        static func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("  FAIL \(why)\n".utf8))
            exit(1)
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
        }

        func showInstallingUpdate(
            withApplicationTerminated applicationTerminated: Bool,
            retryTerminatingApplication: @escaping () -> Void
        ) {
            // Nothing is holding this process open, so it goes away by itself.
            // Sparkle asks again if it does not.
            if !applicationTerminated { retryTerminatingApplication() }
        }

        func showUpdateInstalledAndRelaunched(
            _ relaunched: Bool, acknowledgement: @escaping () -> Void
        ) {
            UpdateHarness.say(relaunched ? "installed and relaunched" : "installed")
            acknowledgement()
            exit(0)
        }

        func dismissUpdateInstallation() {}
    }

#endif
