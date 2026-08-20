import Foundation
import Sparkle
import SwiftUI

/// Software updates.
///
/// Lukotta asks for Full Disk Access and runs part of itself as root, so a
/// working way to ship a fix matters more than usual — a build that broke
/// mounting has already shipped once.
///
/// Updates are verified twice: by Sparkle's EdDSA signature over the archive,
/// and by macOS against the Developer ID signature of the app inside it.
/// Forwards Sparkle's delegate callbacks to a closure.
///
/// The delegate has to be handed to the controller as it is built, and is
/// read-only afterwards, so it cannot be the Updater itself — that object does
/// not exist yet at the point it would have to be passed.
private final class UpdaterRelay: NSObject, SPUUpdaterDelegate {
    var onFailure: ((String) -> Void)?
    var onWillInstall: (() -> Void)?

    /// The last moment the outgoing bundle can be copied: this runs in the
    /// version about to be replaced.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onWillInstall?()
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
        relay.onFailure = { [weak self] message in
            Task { @MainActor in self?.failure = message }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// When Sparkle last managed to ask, so the interface can say rather than
    /// leave the user wondering whether it works at all.
    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }
}
