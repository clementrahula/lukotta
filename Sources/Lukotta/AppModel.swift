import AppKit
import LukottaCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    enum Phase {
        case needsPermission
        case scanning
        case chooseDrive
        case unlock(Drive)
        case working(Drive)
        case chooseVolume(Drive, [LogicalVolume])
        case mounted(Drive, String)
        case failed(Drive?, String, String?)  // drive, summary, raw detail
    }

    @Published var phase: Phase = .scanning
    @Published var drives: [Drive] = []
    @Published var credential: String = ""
    @Published var revealCredential = false
    @Published var statusLines: [String] = []
    /// Stage markers, kept apart from the human-readable log.
    @Published var stageLines: [String] = []
    @Published var credentialProblem: String?
    @Published var showHelp = false
    @Published var showReport = false
    /// Whether to keep this drive's credential in the Keychain. Opt-in.
    @Published var rememberCredential = false
    /// Set when a stored credential was found and filled in, so the interface
    /// can say so rather than showing a field of dots with no explanation.
    @Published var usingSavedCredential = false
    @Published var isEjecting = false
    @Published var ejectProblem: String?

    /// Removes the administrator prompt when installed and approved.
    let helper = HelperClient()

    /// Live permission state, re-checked whenever the app is brought forward
    /// rather than captured once. Granting a permission happens in System
    /// Settings, so the app has to look again when the user comes back.
    @Published var hasFullDiskAccess = true
    /// nil when it cannot be determined.
    @Published var removableAccess: Bool?

    /// True when nothing is outstanding. Drives the panel's summary, so it
    /// cannot claim everything is granted while something still needs doing.
    var allPermissionsSettled: Bool {
        hasFullDiskAccess && helper.isReady
    }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        // Prefer the recorded decision; fall back to evidence. Having opened a
        // drive before is proof the permission was granted, and does not depend
        // on an undocumented database schema continuing to look the same.
        removableAccess = Permissions.removableVolumeAccess() ?? (DriveMemory.hasAny ? true : nil)
        helper.refresh()
    }

    private var workspace: Workspace?
    /// Held only between discovering several volumes and the user picking one,
    /// so the second attempt does not ask for the credential again.
    private var pendingCredential: String?

    // MARK: Lifecycle

    func start() {
        refreshPermissions()
        // Say so before any password is typed, rather than after a failed
        // unlock. Full Disk Access cannot be requested, only detected.
        guard hasFullDiskAccess else {
            phase = .needsPermission
            return
        }
        phase = .scanning
        Task.detached(priority: .userInitiated) {
            // If a drive is already open - the app was reopened, or a previous
            // session left it mounted - go straight to that state.
            let mounts = EngineStatus.current()
            let existing = mounts.first
            let found = DriveScanner.scan()
            await MainActor.run {
                self.drives = found
                self.openMounts = Dictionary(
                    uniqueKeysWithValues:
                        mounts.map { ($0.devicePath, $0.mountPoint) })
                if found.count == 1, existing == nil {
                    // One candidate: asking the user to click the only row is
                    // a step with no decision in it.
                    self.choose(found[0])
                    return
                }
                if let existing {
                    let drive =
                        found.first { $0.devicePath == existing.devicePath }
                        ?? Drive(
                            id: URL(fileURLWithPath: existing.devicePath).lastPathComponent,
                            devicePath: existing.devicePath,
                            name: URL(fileURLWithPath: existing.mountPoint).lastPathComponent,
                            sizeBytes: 0,
                            connection: "",
                            kind: .microsoft,
                            uuid: existing.devicePath)
                    self.phase = .mounted(drive, existing.mountPoint)
                } else {
                    self.phase = .chooseDrive
                }
            }
        }
    }

    /// True while a drive is open, so quitting can offer to eject first.
    ///
    /// Reads cached state rather than spawning the engine: this is consulted on
    /// the main thread while the user is trying to quit, and a subprocess there
    /// stalls the app at exactly the wrong moment.
    var hasOpenDrive: Bool { !openMounts.isEmpty }

    /// Re-probe after the user has changed the setting.
    func recheckPermission() {
        start()
    }

    func openPrivacySettings() {
        Permissions.openFullDiskAccessSettings()
    }

    /// A newly granted permission only applies to a fresh process.
    /// A newly granted permission only applies to a freshly started process.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Discard a stored credential and return to entering one.
    func forgetSavedCredential(for drive: Drive) {
        CredentialStore.delete(for: drive.uuid)
        credential = ""
        rememberCredential = false
        usingSavedCredential = false
        credentialProblem = nil
    }

    func openFilesAndFoldersSettings() {
        Permissions.openFilesAndFoldersSettings()
    }

    func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal the app itself so it can be dragged into the Full Disk Access list.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func rescan() {
        ejectProblem = nil
        credentialBelongsTo = nil
        credential = ""
        credentialProblem = nil
        statusLines = []
        start()
    }

    /// Selecting a drive keeps whatever was typed for that same drive, so a
    /// single mistyped digit in a 48-digit recovery key does not cost all 48.
    private var credentialBelongsTo: String?

    func choose(_ drive: Drive) {
        if credentialBelongsTo != drive.id {
            // A stored credential means the user asked us to remember it.
            if let saved = CredentialStore.load(for: drive.uuid) {
                credential = saved
                rememberCredential = true
                usingSavedCredential = true
            } else {
                credential = ""
                rememberCredential = false
                usingSavedCredential = false
            }
            credentialBelongsTo = drive.id
        }
        credentialProblem = nil
        phase = .unlock(drive)
    }

    func backToDrives() {
        credential = ""
        credentialProblem = nil
        phase = .chooseDrive
    }

    var credentialHint: String? { Credential.hint(for: credential) }

    /// Where a drive is currently open, if it is. Lets the drive list answer
    /// "what is going on" without navigating away from it.
    @Published var openMounts: [String: String] = [:]

    func mountPoint(for drive: Drive) -> String? { openMounts[drive.devicePath] }

    // MARK: Unlock

    /// Mount a specific logical volume after the user has chosen it.
    func choose(_ volume: LogicalVolume, on drive: Drive) {
        guard let credential = pendingCredential else {
            phase = .unlock(drive)
            return
        }
        statusLines = []
        stageLines = []
        phase = .working(drive)
        runMount(drive: drive, credential: credential, volume: volume)
    }

    func unlock(_ drive: Drive) {
        credentialProblem = nil
        let raw = credential
        guard !raw.isEmpty else {
            credentialProblem = "Enter the drive's password, or its 48-digit recovery key."
            return
        }

        switch Credential.normalise(raw) {
        case .failure(let err):
            credentialProblem = err.errorDescription
            return
        case .success(let normalised):
            statusLines = []
            phase = .working(drive)
            let ws: Workspace
            do {
                ws = try Workspace()
            } catch {
                phase = .failed(drive, "Could not create a private working folder.", "\(error)")
                return
            }
            workspace = ws

            runMount(drive: drive, credential: normalised, volume: nil)
        }
    }

    private func runMount(drive: Drive, credential: String, volume: LogicalVolume?) {
        let ws: Workspace
        do {
            ws = try Workspace()
        } catch {
            phase = .failed(drive, "Could not create a private working folder.", "\(error)")
            return
        }
        workspace = ws

        // With the helper approved, this needs no password at all. Without it,
        // fall back to asking macOS to authorise a single command.
        if helper.isReady {
            appendStatus("Using the background helper — no password needed")
            let aliasPath = (try? ws.makeDeviceAlias(named: drive.name, target: drive.devicePath))?
                .path
            Task {
                let outcome = await helper.mount(
                    drive: drive, aliasPath: aliasPath, volume: volume, credential: credential)
                guard let outcome else {
                    // The helper went away; take the ordinary route.
                    self.helper.refresh()
                    self.runMountWithAuthorisation(
                        drive: drive, credential: credential, volume: volume, workspace: ws)
                    return
                }
                for line in outcome.transcript.components(separatedBy: .newlines)
                where !line.isEmpty {
                    self.appendStatus(line)
                }
                if outcome.status == 0,
                    let point = Mounter.discoverMountPoint(
                        for: drive, transcript: outcome.transcript)
                {
                    self.finishMount(drive: drive, credential: credential, mountPoint: point)
                } else {
                    self.phase = .failed(
                        drive,
                        Diagnosis.summarise(outcome.transcript, fallback: ""),
                        outcome.transcript)
                }
            }
            return
        }
        runMountWithAuthorisation(
            drive: drive, credential: credential, volume: volume, workspace: ws)
    }

    /// Record a successful mount, wherever it came from.
    private func finishMount(drive: Drive, credential: String, mountPoint: String) {
        if rememberCredential {
            if !CredentialStore.save(credential, for: drive.uuid) {
                ejectProblem = "The drive opened, but the key could not be saved to your Keychain."
            }
        } else {
            CredentialStore.delete(for: drive.uuid)
        }
        DriveMemory.remember(mountPoint: mountPoint, for: drive.uuid)
        // The user has just proved they can authorise this. Register the helper
        // so the next unlock does not ask again; macOS still requires them to
        // approve it in Login Items, which the panel then prompts for.
        if case .notInstalled = helper.state { helper.install() }
        openMounts[drive.devicePath] = mountPoint
        self.credential = ""
        credentialBelongsTo = nil
        pendingCredential = nil
        phase = .mounted(drive, mountPoint)
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

    private func runMountWithAuthorisation(
        drive: Drive, credential: String, volume: LogicalVolume?, workspace ws: Workspace
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let result = try Mounter.mount(
                    drive: drive,
                    credential: credential,
                    volume: volume,
                    workspace: ws,
                    progress: { line in
                        Task { @MainActor in self.appendStatus(line) }
                    })
                await MainActor.run {
                    // Only store a credential that has actually worked.
                    if self.rememberCredential {
                        if !CredentialStore.save(credential, for: drive.uuid) {
                            self.ejectProblem =
                                "The drive opened, but the key could not be saved to your Keychain."
                        }
                    } else {
                        CredentialStore.delete(for: drive.uuid)
                    }
                    self.credential = ""
                    self.credentialBelongsTo = nil
                    self.pendingCredential = nil
                    // The label is only knowable now. Remember it so the next
                    // unlock can name the share before mounting.
                    DriveMemory.remember(mountPoint: result.mountPoint, for: drive.uuid)
                    self.openMounts[drive.devicePath] = result.mountPoint
                    self.phase = .mounted(drive, result.mountPoint)
                    NSWorkspace.shared.open(URL(fileURLWithPath: result.mountPoint))
                }
            } catch let err as EngineError {
                await MainActor.run {
                    // Several volumes is a question for the user, not a failure:
                    // keep the credential so picking one does not re-prompt.
                    if case .multipleVolumes(let volumes, _) = err {
                        self.pendingCredential = credential
                        self.phase = .chooseVolume(drive, volumes)
                        return
                    }
                    self.pendingCredential = nil
                    if Permissions.isAccessDenied(err.detail ?? "") {
                        self.phase = .needsPermission
                    } else {
                        self.phase = .failed(
                            drive,
                            err.errorDescription ?? "The drive could not be opened.",
                            err.detail)
                    }
                }
            } catch {
                await MainActor.run {
                    self.pendingCredential = nil
                    self.phase = .failed(drive, "The drive could not be opened.", "\(error)")
                }
            }
        }
    }

    private func appendStatus(_ line: String) {
        // Redact as it arrives: the log is shown in the interface, offered in
        // bug reports, and written to the workspace. Doing it here means there
        // is no window in which a credential-shaped string exists in any of
        // those places.
        statusLines.append(Diagnostics.redact(line))
        // Stage markers drive the indicator; they are not output worth reading.
        if line.contains(MountScript.stageMarker) { statusLines.removeLast() }
        if line.contains(MountScript.stageMarker) { stageLines.append(line) }
        if statusLines.count > 400 { statusLines.removeFirst(statusLines.count - 400) }
    }

    // MARK: Post-mount

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// Eject through the engine, not diskutil: diskutil drops the NFS mount but
    /// leaves the microVM running, which orphans a VM on every eject.
    func eject(_ path: String) {
        isEjecting = true
        ejectProblem = nil
        Task.detached(priority: .userInitiated) {
            let result = EngineStatus.unmount(mountPoint: path)
            await MainActor.run {
                self.isEjecting = false
                if result.ok {
                    self.openMounts = self.openMounts.filter { $0.value != path }
                    self.rescan()
                } else {
                    self.ejectProblem = result.message
                }
            }
        }
    }

    /// Eject everything, then run the completion. Used on quit.
    func ejectAll(completion: @escaping () -> Void) {
        Task.detached(priority: .userInitiated) {
            for m in EngineStatus.current() {
                _ = EngineStatus.unmount(mountPoint: m.mountPoint)
            }
            await MainActor.run { completion() }
        }
    }

    /// Remove the private workspace. Called when the app quits so nothing of
    /// this session is left behind.
    func cleanUp() {
        workspace?.destroy()
        workspace = nil
    }
}
