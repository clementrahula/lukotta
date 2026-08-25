// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import Foundation
import LukottaCore
import ServiceManagement

/// Removing Lukotta from the machine.
///
/// Dragging the app to the Bin is not enough: the privileged helper is
/// registered with launchd, which knows about the service rather than the
/// folder it came from, so it stays behind with nothing to serve. Only the app
/// that registered it can withdraw it, which is why this belongs in the app.
@MainActor
enum Uninstall {

    /// What removal would take away, in the order it happens.
    struct Plan {
        var openDrives: [String] = []
        var helperRegistered = false
        var guestSizeMB: Int?
        var hasPreferences = false
        /// Drives a passphrase is stored for, named where the name is known.
        var savedPassphrases: [String] = []
    }

    /// This app's own engine directory, inside its own Application Support.
    /// Nothing else on the Mac keeps anything here, so removing it takes away
    /// this app's Linux environment and nobody else's.
    nonisolated private static var guest: URL { EngineEnvironment.engineHome }

    /// Sparkle's own cache: the feed it fetched and the icons in it. Nothing
    /// of the drive app, but it is in this app's name and would outlive it.
    nonisolated private static var caches: URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    nonisolated private static var support: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent("Lukotta", isDirectory: true)
    }

    /// Look before offering, so the confirmation describes this Mac rather than
    /// a general case.
    static func survey() -> Plan {
        var plan = Plan()
        plan.openDrives = EngineStatus.current().map(\.mountPoint)
        plan.helperRegistered =
            SMAppService.daemon(plistName: HelperInfo.plistName).status != .notRegistered
        if let size = try? FileManager.default.allocatedSizeOfDirectory(at: guest) {
            plan.guestSizeMB = Int(size / 1_000_000)
        }
        plan.hasPreferences =
            UserDefaults.standard.persistentDomain(forName: bundleIdentifier) != nil
        plan.savedPassphrases = CredentialStore.savedDrives().map {
            DriveMemory.knownName(for: $0) ?? "an unnamed drive"
        }
        return plan
    }

    nonisolated private static var bundleIdentifier: String { HelperInfo.appIdentifier }

    /// One line of the uninstall, and whether it has finished.
    struct Step: Identifiable {
        let id = UUID()
        let label: String
        var done = false
    }

    static func steps(for plan: Plan, removingPassphrases: Bool) -> [Step] {
        var steps: [Step] = []
        if !plan.openDrives.isEmpty {
            steps.append(
                Step(
                    label: String(localized: "Ejecting \(plan.openDrives.count) open drives")))
        }
        if plan.helperRegistered {
            steps.append(
                Step(label: String(localized: "Unregistering the background helper")))
        }
        if plan.guestSizeMB != nil {
            steps.append(Step(label: String(localized: "Deleting the Linux environment")))
        }
        steps.append(Step(label: String(localized: "Removing settings")))
        if removingPassphrases, !plan.savedPassphrases.isEmpty {
            steps.append(
                Step(
                    label: String(
                        localized: "Deleting \(plan.savedPassphrases.count) saved passphrases")))
        }
        steps.append(Step(label: String(localized: "Moving \(Brand.name) to the Bin")))
        return steps
    }

    /// Eject, unregister, delete, then move the app to the Bin and quit.
    ///
    /// Saved passphrases go only if asked for. Some are 48-digit recovery keys
    /// that exist nowhere else, so removing them is a decision the user makes
    /// rather than one an uninstall makes quietly.
    static func perform(
        _ plan: Plan,
        removingPassphrases: Bool,
        advance: @escaping @MainActor @Sendable (Int) -> Void,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            var step = 0
            func finished() { let n = step; step += 1; Task { @MainActor in advance(n) } }

            if !plan.openDrives.isEmpty {
                for point in plan.openDrives { _ = EngineStatus.unmount(mountPoint: point) }
                finished()
            }
            if plan.helperRegistered {
                // The addresses the helper added for serving drives, while it
                // is still there to take them back. They would go at the next
                // restart anyway; leaving somebody to restart before their Mac
                // is as they left it is not uninstalling.
                await AppModel.shared.helper.releaseRoom()
                await MainActor.run {
                    try? SMAppService.daemon(plistName: HelperInfo.plistName).unregister()
                }
                finished()
            }
            // The section this app wrote goes whatever happens; it is named
            // after this app and means nothing to anything else.
            EngineConfig.removeGeneratedAction()
            if plan.guestSizeMB != nil {
                try? FileManager.default.removeItem(at: guest)
                finished()
            }
            await MainActor.run {
                if let support { try? FileManager.default.removeItem(at: support) }
                if let caches { try? FileManager.default.removeItem(at: caches) }
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
                DriveMemory.forgetEverything()
            }
            // The scratch directories, the empty mount points, everything.
            // After this there is no app to do it at the next launch.
            Housekeeping.sweep()
            finished()

            if removingPassphrases {
                for uuid in CredentialStore.savedDrives() { CredentialStore.delete(for: uuid) }
                finished()
            }

            let last = step
            let message = await moveToTheBin(Bundle.main.bundleURL)
            await MainActor.run {
                advance(last)
                completion(message)
            }
        }
    }
}

/// Put the application in the Bin, and say what went wrong if anything did.
///
/// Deliberately not written as a closure handed to `recycle` from the main
/// actor. Where `recycle` calls back is undocumented, and a closure created in
/// main-actor code carries that isolation with it: running it anywhere else
/// traps under Swift 6 rather than merely being wrong. Made here, outside any
/// actor, it carries none.
///
/// recycle() rather than a delete: a change of mind then costs nothing.
private func moveToTheBin(_ url: URL) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        let once = ResumeOnceMessage(continuation)
        NSWorkspace.shared.recycle([url]) { _, error in
            once.resume(error?.localizedDescription)
        }
    }
}

/// One resume, whatever arrives and from wherever.
private final class ResumeOnceMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension FileManager {
    /// Size of a directory tree, for saying how much removing it frees.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        guard let walk = enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey])
            total += UInt64(values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
