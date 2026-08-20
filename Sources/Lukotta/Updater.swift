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

    init() {
        // startingUpdater: true begins the scheduled check cycle. The user is
        // asked on first run whether automatic checks are wanted.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
