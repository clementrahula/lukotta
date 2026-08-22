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
                Task { @MainActor [weak self] in self?.connection = nil }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? LukottaHelperProtocol
    }

    /// One round trip to the helper, off the main actor.
    ///
    /// `nonisolated`, and that is the whole point. XPC calls both the reply and
    /// the error handler on a private queue. A continuation created inside a
    /// `@MainActor` method carries that isolation, and resuming it from another
    /// queue trips Swift 6's isolation check and kills the process — which is
    /// exactly what happened the first time a helper too old to answer sent the
    /// call to its error handler. Under Swift 5 the same code ran, because
    /// nothing was checking.
    ///
    /// The error handler is not optional either: an XPC call to a method the
    /// peer does not implement never calls its reply, so without it this would
    /// hang, and leak, on every attempt.
    private nonisolated static func roundTrip<T: Sendable>(
        _ box: ConnectionBox,
        _ send:
            @escaping @Sendable (LukottaHelperProtocol, @escaping @Sendable (T?) -> Void) ->
            Void
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            guard
                let proxy = box.connection
                    .remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) })
                    as? LukottaHelperProtocol
            else { return once.resume(nil) }
            send(proxy) { once.resume($0) }
        }
    }

    /// The running mount's output so far, or nil if it cannot be had.
    func progress() async -> String? {
        guard isReady, proxy() != nil, let connection else { return nil }
        return await Self.roundTrip(ConnectionBox(connection)) { proxy, done in
            proxy.progress { done($0) }
        }
    }

    /// What a partition holds, read from its first sector by the helper.
    ///
    /// Unknown when the helper is not there, or is an older one without the
    /// method: nothing is claimed about the drive and the screen says what it
    /// always said.
    func identify(devicePath: String) async -> VolumeFormat {
        guard isReady, proxy() != nil, let connection else { return .unknown }
        let answer: String? = await Self.roundTrip(ConnectionBox(connection)) { proxy, done in
            proxy.identify(devicePath: devicePath) { done($0) }
        }
        return answer.flatMap(VolumeFormat.init(rawValue:)) ?? .unknown
    }

    /// Force the error handler to run, for `--check-helper`.
    ///
    /// An invalidated connection replies to nothing and calls its error handler
    /// instead, which is the path that killed the app: it arrives on XPC's own
    /// queue, and anything main-actor isolated waiting there traps.
    func identifyOverABrokenConnection(devicePath: String) async -> VolumeFormat {
        guard proxy() != nil, let connection else { return .unknown }
        connection.invalidate()
        self.connection = nil
        let answer: String? = await Self.roundTrip(ConnectionBox(connection)) { proxy, done in
            proxy.identify(devicePath: devicePath) { done($0) }
        }
        return answer.flatMap(VolumeFormat.init(rawValue:)) ?? .unknown
    }

    /// Mount through the helper. Returns nil when it is unavailable, so the
    /// caller can fall back rather than fail.
    func mount(
        drive: Drive, aliasPath: String?, volume: LogicalVolume?, credential: String,
        readOnly: Bool = false
    ) async -> (status: Int32, transcript: String)? {
        guard isReady, proxy() != nil, let connection else { return nil }
        let devicePath = drive.devicePath
        let isLinux = drive.kind == .linux
        let identifier = volume?.mountIdentifier
        let answer = await Self.roundTrip(ConnectionBox(connection)) { proxy, done in
            proxy.mount(
                devicePath: devicePath,
                aliasPath: aliasPath,
                isLinux: isLinux,
                volumeIdentifier: identifier,
                credential: credential,
                readOnly: readOnly
            ) { status, transcript in
                done((status: status, transcript: transcript))
            }
        }
        if answer != nil { return answer }

        // A helper older than this method never answers it, and the app may
        // have been updated while it kept running. A read-write mount can still
        // be asked for through the selector it does have; a read-only one
        // cannot, and saying so is better than mounting a drive writable when
        // read-only was chosen.
        guard !readOnly, let connection = self.connection else { return answer }
        Log.helper.notice("falling back to the older mount method")
        return await Self.roundTrip(ConnectionBox(connection)) { proxy, done in
            proxy.mount(
                devicePath: devicePath,
                aliasPath: aliasPath,
                isLinux: isLinux,
                volumeIdentifier: identifier,
                credential: credential
            ) { status, transcript in
                done((status: status, transcript: transcript))
            }
        }
    }
}

/// Carries the connection across to a nonisolated context.
///
/// `NSXPCConnection` is thread-safe by design — it exists to be called from
/// whatever queue has work for it — and is not marked `Sendable`. Saying so
/// once, here, rather than conforming a Foundation class on its behalf.
private struct ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Guarantees a continuation is resumed exactly once, whichever of the reply
/// and the error handler arrives — both may, and neither is on a known queue.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
