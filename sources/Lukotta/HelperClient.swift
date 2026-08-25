// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import LukottaCore
import Security
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
        /// The password has been asked for and the answer is not in yet.
        case installing
        case awaitingApproval
        case ready
        case failed(String)
    }

    /// Asked at once rather than assumed absent.
    ///
    /// launchd answers this without touching a disk, and starting at
    /// notInstalled meant every screen that mentions the helper drew "not set
    /// up" first and corrected itself a moment later, on a Mac where it has
    /// been set up for months.
    @Published private(set) var state: State = {
        switch SMAppService.daemon(plistName: HelperInfo.plistName).status {
        case .enabled: return .ready
        case .requiresApproval: return .awaitingApproval
        default: return .notInstalled
        }
    }()

    /// The build of the daemon actually running, as it last answered.
    ///
    /// launchd keeps a registered daemon across an app update, so this is not
    /// always the build in the bundle -- which is the whole reason the question
    /// is asked. A report that states both is answerable; one that states the
    /// app's own version twice is not.
    @Published private(set) var installedVersion: String?

    /// Whether the daemon has been asked to prove it is running this session.
    /// Once is enough: every mount asks it something anyway.
    private var hasConfirmed = false

    private var connection: NSXPCConnection?
    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperInfo.plistName)
    }

    func refresh() {
        // A daemon installed with an administrator password is a launchd job,
        // not a service this app registered, so SMAppService says nothing about
        // it. The job on disk is evidence that it was installed -- not that it
        // runs, which is a different thing and the one that matters. So the
        // screen says ready and the daemon is asked to confirm it; if it never
        // answers, the state drops to one with a button on it.
        if FileManager.default.fileExists(atPath: HelperInfo.installedJobPath) {
            if state != .ready { state = .ready }
            if !hasConfirmed {
                hasConfirmed = true
                confirmItIsReallyThere()
            }
            return
        }
        switch service.status {
        case .enabled: state = .ready
        case .requiresApproval: state = .awaitingApproval
        case .notRegistered, .notFound: state = .notInstalled
        @unknown default: state = .notInstalled
        }
    }

    /// Replace the running daemon when it is not the one in this app.
    ///
    /// launchd keeps a registered daemon running across an app update: the
    /// binary inside the bundle is replaced and the job is not. So a fixed app
    /// went on behaving exactly as the broken one had -- the helper builds the
    /// mount itself, and it was still building it the old way. Nothing said so,
    /// because from the outside the app was the new version and the fault was
    /// the old one.
    ///
    /// The helper is asked what it is. An answer that does not match, or no
    /// answer at all -- an older helper that does not know the question --
    /// means the job is stale, and it is registered again. Silent: the daemon
    /// is already approved, and this is not something to make anybody read.
    func replaceIfStale() {
        guard case .ready = state else { return }
        // A daemon installed with an administrator password is not this app's
        // to re-register: unregistering reaches nothing, and registering again
        // would install the other kind beside it. The one running has to be
        // taken away first, and putting the new one back asks for the password
        // again -- so it is offered rather than done, and the drive in front of
        // somebody still opens through the older daemon meanwhile.
        if FileManager.default.fileExists(atPath: HelperInfo.installedJobPath) {
            askVersion { [weak self] theirs in
                guard let self else { return }
                let mine =
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                guard !mine.isEmpty, !theirs.isEmpty, theirs != mine else { return }
                Log.app.notice(
                    "the installed helper is build \(theirs, privacy: .public), this is \(mine, privacy: .public); asking to set it up again"
                )
                self.state = .failed(
                    appString("This version needs setting up again. It takes one password."))
            }
            return
        }
        let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !mine.isEmpty else { return }
        askVersion { [weak self] theirs in
            guard let self, theirs != mine else { return }
            Log.app.notice(
                "the running helper is build \(theirs.isEmpty ? "unknown" : theirs, privacy: .public), this is \(mine, privacy: .public); registering it again"
            )
            self.connection?.invalidate()
            self.connection = nil
            try? self.service.unregister()
            // launchd takes a moment to tear the job down; registering into one
            // that is still going away leaves it notRegistered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                try? self.service.register()
                self.refresh()
                // The one just registered is the one that knows how to make
                // room; the one that was running when this started may not.
                self.makeRoomForDrives()
            }
        }
    }

    /// Ask the helper for enough loopback addresses that a dozen drives can be
    /// open at once. Idempotent, and silent where there is no helper: the app
    /// then runs on the three addresses macOS provides and says so.
    func makeRoomForDrives(_ count: Int = Capacity.wanted) {
        guard case .ready = state, proxy() != nil, let connection else { return }
        // Through roundTrip, and not through the proxy directly. A helper too
        // old to know this method never replies: XPC calls the error handler
        // instead, on its own queue, and a closure written in a @MainActor
        // method carries that isolation with it. Running it anywhere else traps
        // under Swift 6 and takes the app down -- which is exactly what
        // happened here, on the first launch after this method was added, with
        // the previous helper still running.
        let box = ConnectionBox(connection)
        Task.detached {
            let have: Int? = await Self.roundTrip(box) { proxy, done in
                proxy.makeRoom(forDrives: count) { done($0) }
            }
            guard let have else {
                Log.app.notice("this helper cannot make room; three drives at once")
                return
            }
            Log.app.notice("room for \(have, privacy: .public) drives at once")
        }
    }

    /// Give back the loopback addresses, for uninstalling. Waits, because the
    /// daemon is unregistered next.
    func releaseRoom() async {
        guard case .ready = state, proxy() != nil, let connection else { return }
        let box = ConnectionBox(connection)
        let left: Int? = await Self.roundTrip(box) { proxy, done in
            proxy.makeRoom(forDrives: 0) { done($0) }
        }
        Log.app.notice("loopback addresses left: \(left ?? -1, privacy: .public)")
    }

    /// Ask the daemon to take itself off the Mac.
    ///
    /// Waited for, because what follows is the app deleting itself: a reply
    /// that arrives after the app has gone is a daemon still installed.
    private func removeItself() {
        guard FileManager.default.fileExists(atPath: HelperInfo.installedJobPath) else { return }
        guard proxy() != nil, let connection else { return }
        let box = ConnectionBox(connection)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await Self.roundTrip(box) { proxy, reply in
                proxy.removeYourself { reply($0) }
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 10)
    }

    private func askVersion(_ done: @escaping @MainActor (String) -> Void) {
        guard proxy() != nil, let connection else { return done("") }
        // The same rule as everything else that talks to the helper: the reply
        // and the error both arrive on XPC's own queue, so the call is made
        // from nowhere in particular and the answer is carried back to the main
        // actor by hand.
        let box = ConnectionBox(connection)
        Task.detached {
            let version: String? = await Self.roundTrip(box) { proxy, reply in
                proxy.helperVersion { reply($0) }
            }
            await MainActor.run { [weak self] in
                self?.installedVersion = (version?.isEmpty ?? true) ? nil : version
                done(version ?? "")
            }
        }
    }

    /// Install the daemon, asking for an administrator password once.
    ///
    /// Two routes exist and they ask for different things.
    ///
    /// `SMJobBless` takes an administrator password, checks that the app and
    /// the helper each satisfy the code requirement the other names, installs
    /// the daemon and starts it. One password, and nothing else to do. It is
    /// what every application on a Mac with a privileged helper has done for
    /// years, and it is deprecated.
    ///
    /// `SMAppService` is what replaced it. It needs no password -- and instead
    /// leaves the daemon switched off until somebody finds the app in System
    /// Settings and turns it on. That is a second step, in another application,
    /// for something they have already agreed to.
    ///
    /// So the first is tried and the second is the fallback, which is also what
    /// happens if a future macOS finally removes the older one.
    func install() {
        guard state != .installing else { return }
        hasConfirmed = true
        state = .installing
        Task.detached(priority: .userInitiated) { [weak self] in
            // The password panel is put up by the system on this thread, so it
            // is not the one drawing the interface.
            let blessed = HelperClient.blessWithAuthorisation()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if blessed {
                    Log.app.notice("the helper was installed with an administrator password")
                } else if FileManager.default.fileExists(atPath: HelperInfo.installedJobPath) {
                    // One is already installed the other way. Registering now
                    // would put a second daemon beside it, both claiming the
                    // same mach service, and which one answered would be
                    // whichever launchd reached first.
                    Log.app.notice("a daemon is already installed; not registering a second")
                } else {
                    // The other route needs no password. It leaves the daemon
                    // switched off until somebody turns it on in Settings, and
                    // that is what the screen then says.
                    do { try self.service.register() } catch {
                        Log.app.error("the helper could not be registered: \(error)")
                    }
                }
                self.confirmItIsReallyThere()
            }
        }
    }

    /// Ask the daemon what it is, until it answers or it is plainly not coming.
    ///
    /// Installing is two things -- a job written down, and a process launchd
    /// will start -- and the first can happen without the second. Believing the
    /// file on disk meant the screen said the helper was set up while every
    /// unlock went on asking for a password, with nothing anywhere admitting
    /// the two disagreed.
    private func confirmItIsReallyThere(attempts: Int = 12) {
        askVersion { [weak self] version in
            guard let self else { return }
            if !version.isEmpty {
                self.state = .ready
                Log.app.notice("the helper answered; it is set up")
                return
            }
            guard attempts > 1 else {
                // Not there, and not coming. Whatever the reason -- a password
                // panel somebody closed, a job that will not start -- the
                // screen says so and the button asks again.
                if self.service.status == .requiresApproval {
                    self.state = .awaitingApproval
                } else {
                    self.state = .failed(
                        appString("Setting up did not finish. You can try again."))
                }
                Log.app.error("the helper did not answer after being installed")
                return
            }
            // launchd takes a moment to start a job it has just been given.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.confirmItIsReallyThere(attempts: attempts - 1)
            }
        }
    }

    /// The older route: authorise, then let macOS install and start the daemon.
    ///
    /// Returns false for anything that did not work, including somebody
    /// cancelling the password panel -- the caller then offers the other route
    /// rather than treating it as a failure.
    private nonisolated static func blessWithAuthorisation() -> Bool {
        var authorisation: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorisation) == errAuthorizationSuccess,
            let authorisation
        else { return false }
        defer { AuthorizationFree(authorisation, []) }

        // The name has to outlive the call. Taking a pointer inside
        // withCString and using it after that closure returns is a pointer to
        // memory that is no longer anybody's -- it happens to work until it
        // does not, and this one asks for a right to install a root daemon.
        return kSMRightBlessPrivilegedHelper.withCString { name -> Bool in
            var right = AuthorizationItem(
                name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { item -> Bool in
                var rights = AuthorizationRights(count: 1, items: item)
                let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
                guard
                    AuthorizationCopyRights(authorisation, &rights, nil, flags, nil)
                        == errAuthorizationSuccess
                else { return false }

                var failure: Unmanaged<CFError>?
                let blessed = SMJobBless(
                    kSMDomainSystemLaunchd, HelperInfo.machServiceName as CFString, authorisation,
                    &failure)
                if !blessed, let failure {
                    let error = failure.takeRetainedValue()
                    Log.app.error("the helper could not be installed: \(error, privacy: .public)")
                }
                return blessed
            }
        }
    }

    func remove() {
        // Whichever way it was installed. The daemon takes itself away when it
        // is the one launchd loaded from /Library, since removing that needs
        // root and it already has it; unregistering covers the other route.
        removeItself()
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
