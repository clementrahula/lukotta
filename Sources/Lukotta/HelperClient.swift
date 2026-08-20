import Foundation
import LukottaCore
import ServiceManagement

/// Talks to the privileged helper, and installs it on request.
///
/// With the helper registered, unlocking needs no administrator password: the
/// daemon already runs as root. Without it, the app falls back to asking macOS
/// to authorise a single command, which is what it did before. Nothing breaks
/// if the helper is unavailable or the user declines it.
@MainActor
final class HelperClient: ObservableObject {

    enum State: Equatable {
        case notInstalled
        case awaitingApproval
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    private var connection: NSXPCConnection?
    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperInfo.plistName)
    }

    func refresh() {
        switch service.status {
        case .enabled: state = .ready
        case .requiresApproval: state = .awaitingApproval
        case .notRegistered, .notFound: state = .notInstalled
        @unknown default: state = .notInstalled
        }
    }

    /// Register the daemon. macOS then asks the user to approve it in Login
    /// Items; until they do, the status is requiresApproval.
    func install() {
        do {
            try service.register()
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        try? service.unregister()
        connection?.invalidate()
        connection = nil
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var isReady: Bool { state == .ready }

    // MARK: Calling it

    private func proxy() -> LukottaHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(
                machServiceName: HelperInfo.machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: LukottaHelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? LukottaHelperProtocol
    }

    /// Mount through the helper. Returns nil when it is unavailable, so the
    /// caller can fall back rather than fail.
    func mount(
        drive: Drive, aliasPath: String?, volume: LogicalVolume?, credential: String
    ) async -> (status: Int32, transcript: String)? {
        guard isReady, let proxy = proxy() else { return nil }
        return await withCheckedContinuation { continuation in
            var resumed = false
            proxy.mount(
                devicePath: drive.devicePath,
                aliasPath: aliasPath,
                isLinux: drive.kind == .linux,
                volumeIdentifier: volume?.mountIdentifier,
                credential: credential
            ) { status, transcript in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (status, transcript))
            }
        }
    }
}
