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
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

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
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        canCheck = controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// When Sparkle last managed to ask, so the interface can say rather than
    /// leave the user wondering whether it works at all.
    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }
}
