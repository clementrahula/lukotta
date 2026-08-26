// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import Sparkle
import SwiftUI

// Software updates. Lukotta asks for Full Disk Access and runs part of itself
// as root, so a working way to ship a fix matters more than usual. Updates are
// verified twice: by Sparkle's EdDSA signature over the archive, and by macOS
// against the Developer ID signature of the app inside it.

/// Forwards Sparkle's delegate callbacks to a closure.
///
/// The delegate has to be handed to the controller as it is built, and is
/// read-only afterwards, so it cannot be the Updater itself — that object does
/// not exist yet at the point it would have to be passed.
final class UpdaterRelay: NSObject, SPUUpdaterDelegate {
    var onFailure: ((String) -> Void)?
    var onWillInstall: (() -> Void)?
    /// This version is done; the installer takes it from here.
    var onWillHandOver: (() -> Void)?
    /// Answers whether a drive is open that the app itself is holding.
    var isHoldingADrive: (() -> Bool)?

    /// Keep the outgoing bundle, at every point Sparkle offers before the swap.
    ///
    /// Which of these arrive is not a matter of reading the documentation:
    /// driving a real update through shows that the download and the extraction
    /// do and that willInstallUpdate does not. Hanging the copy on one callback
    /// is how the rollback ended up with nothing to put back, so it hangs on
    /// all three. Copying twice costs a ditto of a bundle already on this disk.
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        onWillInstall?()
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        onWillInstall?()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onWillInstall?()
        // Belt and braces with willRelaunch: which of Sparkle's callbacks
        // arrive is not a matter of reading the documentation, and the watcher
        // is started once however many times it is asked for.
        onWillHandOver?()
    }

    /// Do not replace the app while it is the thing holding a drive open.
    ///
    /// Installing pulls the engine out from under a running virtual machine.
    /// With the helper installed the machine belongs to launchd and survives,
    /// so only the case where the app itself owns it has to wait — and it waits
    /// rather than refuses, so the update installs on quit.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    /// The last moment this version is the one running.
    ///
    /// Sparkle replaces the bundle after this app has quit, so nothing here
    /// can look at what arrives. What it can do is leave something behind that
    /// will.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onWillHandOver?()
    }


    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard isHoldingADrive?() == true else { return false }
        pendingInstall = installHandler
        return true
    }

    /// Held until the drive it would have interrupted is ejected.
    private(set) var pendingInstall: (() -> Void)?

    func installWhenReady() {
        guard let pendingInstall else { return }
        self.pendingInstall = nil
        pendingInstall()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Finding no update, and being told to stop, are not failures.
        let code = Int32((error as NSError).code)
        guard code != SUError.noUpdateError.rawValue,
            code != SUError.installationCanceledError.rawValue
        else { return }
        onFailure?(describe(error))
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        var lines = ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
        if let reason = ns.localizedFailureReason { lines.append(reason) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(
                "caused by \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private let relay = UpdaterRelay()

    /// Set when an update could not be installed, so the user is told rather
    /// than left on an old build wondering why nothing arrives.
    @Published var failure: String?

    /// Set by the app: true while this process is the one keeping a drive open.
    var holdsADrive: (() -> Bool)?

    /// An update that was waiting for a drive to be ejected.
    var updateIsWaiting: Bool { relay.pendingInstall != nil }

    /// Called once nothing is open, so a postponed update can go ahead.
    func installPostponedUpdate() { relay.installWhenReady() }

    @Published var canCheck = false

    /// Mirrors of Sparkle's own settings, so the interface can offer them.
    ///
    /// Sparkle stores these itself and they survive a restart; these hold the
    /// current value so a toggle has something to bind to.
    @Published var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    @Published var downloadsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = downloadsAutomatically }
    }

    init() {
        // startingUpdater: true begins the scheduled check cycle. The app ships
        // with automatic checks already on, so Sparkle does not ask.
        let relay = self.relay
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: relay, userDriverDelegate: nil)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        canCheck = controller.updater.canCheckForUpdates
        relay.onWillInstall = { Rollback.keepCurrentAside() }
        relay.onWillHandOver = { Rollback.watchTheUpdateLand() }
        // Only the app holding a drive itself has to postpone: a drive held by
        // the helper belongs to launchd and survives the app being replaced.
        relay.isHoldingADrive = { [weak self] in self?.holdsADrive?() ?? false }
        relay.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in self?.failure = message }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// When Sparkle last managed to ask, so the interface can say rather than
    /// leave the user wondering whether it works at all.
    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }
}
