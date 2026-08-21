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
        var savedCredentials = false
    }

    private static var guest: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anylinuxfs", isDirectory: true)
    }

    private static var support: URL? {
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
        plan.savedCredentials = CredentialStore.hasAny
        return plan
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.clementrahula.lukotta"
    }

    /// Eject, unregister, delete, then move the app to the Bin and quit.
    ///
    /// Saved passphrases are deliberately untouched: some are 48-digit recovery
    /// keys that exist nowhere else, and deleting them quietly during an
    /// uninstall would be indefensible.
    static func perform(_ plan: Plan, completion: @escaping (String?) -> Void) {
        Task.detached(priority: .userInitiated) {
            for point in plan.openDrives {
                _ = EngineStatus.unmount(mountPoint: point)
            }
            await MainActor.run {
                if plan.helperRegistered {
                    try? SMAppService.daemon(plistName: HelperInfo.plistName).unregister()
                }
                EngineConfig.removeGeneratedAction()
                try? FileManager.default.removeItem(at: guest)
                if let support { try? FileManager.default.removeItem(at: support) }
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)

                // recycle() puts it in the Bin rather than deleting it, so a
                // change of mind costs nothing.
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                    completion(error?.localizedDescription)
                }
            }
        }
    }
}

extension FileManager {
    /// Size of a directory tree, for saying how much removing it frees.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        guard let e = enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in e {
            let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey])
            total += UInt64(values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
