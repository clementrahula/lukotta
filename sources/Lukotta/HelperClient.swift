import Foundation
import LukottaCore
import ServiceManagement

/// Talks to the privileged helper, and installs it on request.
///
/// With the helper registered, unlocking needs no administrator password: the
/// daemon already runs as root. Without it, the app falls back to asking macOS
/// to authorise a single command. Nothing breaks if the helper is unavailable
/// or the user declines it.
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

    /// The running mount's output so far, or nil if it cannot be had.
    ///
    /// A helper installed by an earlier version has no such method, and an XPC
    /// call to a method the peer does not implement never calls its reply. The
    /// error handler is what resumes the continuation in that case; without it
    /// this would hang, and leak, on every poll.
    func progress() async -> String? {
        guard isReady, proxy() != nil, let connection else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) })
                    as? LukottaHelperProtocol
            else { return once.resume(nil) }
            proxy.progress { once.resume($0) }
        }
    }

    /// What a partition holds, read from its first sector by the helper.
    ///
    /// Unknown when the helper is not there, which is the same as not asking:
    /// nothing is claimed about the drive and the screen says what it always
    /// said. A helper from an earlier version has no such method, and the
    /// error handler is what stops that hanging for ever.
    func identify(devicePath: String) async -> VolumeFormat {
        guard isReady, proxy() != nil, let connection else { return .unknown }
        let answer = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) })
                    as? LukottaHelperProtocol
            else { return once.resume(nil) }
            proxy.identify(devicePath: devicePath) { once.resume($0) }
        }
        return answer.flatMap(VolumeFormat.init(rawValue:)) ?? .unknown
    }

    /// Mount through the helper. Returns nil when it is unavailable, so the
    /// caller can fall back rather than fail.
    func mount(
        drive: Drive, aliasPath: String?, volume: LogicalVolume?, credential: String
    ) async -> (status: Int32, transcript: String)? {
        guard isReady, proxy() != nil, let connection else { return nil }
        return await withCheckedContinuation { continuation in
            // Returning nil rather than never returning. Without an error
            // handler a helper that has gone away — restarted, crashed,
            // replaced by an update — leaves this waiting for a reply that
            // cannot arrive, and the app sits on "Unlocking and mounting" for
            // ever. The caller falls back to asking for authorisation instead.
            let once = ResumeOnceOutcome(continuation)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) })
                    as? LukottaHelperProtocol
            else { return once.resume(nil) }
            proxy.mount(
                devicePath: drive.devicePath,
                aliasPath: aliasPath,
                isLinux: drive.kind == .linux,
                volumeIdentifier: volume?.mountIdentifier,
                credential: credential
            ) { status, transcript in
                once.resume((status, transcript))
            }
        }
    }
}

/// Guarantees a continuation is resumed exactly once, whichever of the reply
/// and the error handler arrives — both may, and neither is on a known queue.
private final class ResumeOnce: @unchecked Sendable {
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

/// The same guarantee as ResumeOnce, for the mount reply's pair.
private final class ResumeOnceOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(status: Int32, transcript: String)?, Never>?

    init(_ continuation: CheckedContinuation<(status: Int32, transcript: String)?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: (status: Int32, transcript: String)?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
