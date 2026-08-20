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
    /// Which step a failed mount got to, so the failure can point at it rather
    /// than replacing the steps with a bare sentence.
    @Published var failedStage: MountStage?
    /// Every volume opened for the drive on screen. A container can hold more
    /// than one, and all of them are opened rather than asking which.
    @Published var openVolumes: [String] = []
    @Published var isEjecting = false
    @Published var ejectProblem: String?
    /// Explains something that happened before the user was looking, such as a
    /// drive that dropped while the app was not running.
    @Published var notice: String?

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

    /// Watches for drives arriving and leaving while the app is open.
    private lazy var watcher = DiskWatcher { [weak self] in
        Task { @MainActor in self?.driveSetChanged() }
    }

    /// The drive on screen, whichever way it is being shown.
    private var currentDrive: Drive? {
        switch phase {
        case .unlock(let drive), .working(let drive), .mounted(let drive, _): return drive
        default: return nil
        }
    }

    /// A drive was plugged in or pulled out.
    ///
    /// Refreshes the list in place. A drive the user is looking at that has
    /// gone away is worth interrupting for — the alternative is a screen
    /// offering to unlock something that is no longer attached, or claiming a
    /// drive is open when it has been pulled out from under the mount.
    private func driveSetChanged() {
        Task.detached(priority: .userInitiated) {
            let found = DriveScanner.scan()
            let mounts = EngineStatus.current()
            await MainActor.run {
                let vanished =
                    self.currentDrive.map { drive in
                        !found.contains { $0.devicePath == drive.devicePath }
                    } ?? false

                self.drives = found
                self.openMounts = Dictionary(
                    mounts.map { ($0.devicePath, $0.mountPoint) },
                    uniquingKeysWith: { first, _ in first })

                guard vanished, let drive = self.currentDrive else { return }
                // Whatever was mounted from it cannot be reached any more, and
                // leaving the mount behind is what makes macOS ask about a
                // server that will never answer.
                let name = drive.name
                Task.detached(priority: .userInitiated) {
                    for point in EngineStatus.stale() {
                        EngineStatus.forceUnmount(mountPoint: point)
                    }
                }
                self.openVolumes = []
                self.openMounts = self.openMounts.filter { !$0.key.contains(drive.id) }
                self.notice = "“\(name)” was disconnected."
                self.credential = ""
                self.credentialProblem = nil
                self.phase = .chooseDrive
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        watcher.start()
        refreshPermissions()
        // Say so before any password is typed, rather than after a failed
        // unlock. Full Disk Access cannot be requested, only detected.
        guard hasFullDiskAccess else {
            phase = .needsPermission
            return
        }
        phase = .scanning
        Task.detached(priority: .userInitiated) {
            // Clear anything left mounted by a virtual machine that is no
            // longer running. Until it goes, macOS keeps asking the user about
            // a server that cannot answer, and the drive cannot be opened
            // again because its mount point is still occupied.
            let abandoned = EngineStatus.stale()
            for point in abandoned { EngineStatus.forceUnmount(mountPoint: point) }

            // If a drive is already open - the app was reopened, or a previous
            // session left it mounted - go straight to that state.
            let mounts = EngineStatus.current()
            let existing = mounts.first
            let found = DriveScanner.scan()
            await MainActor.run {
                self.drives = found
                if let name = abandoned.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                    self.notice =
                        abandoned.count > 1
                        ? "\(abandoned.count) drives had stopped responding and were disconnected. You can open them again."
                        : "“\(name)” had stopped responding and was disconnected. You can open it again."
                }
                self.openMounts = Dictionary(
                    mounts.map { ($0.devicePath, $0.mountPoint) },
                    uniquingKeysWith: { first, _ in first })
                // Far enough to be working: permissions read, drives scanned,
                // a window on screen. Reaching main is not enough — a build
                // that starts and then falls over must still count as failed.
                Rollback.confirmHealthy()
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
                    self.collectVolumes(for: drive, fallback: existing.mountPoint)
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
        // Left on: forgetting is how a key gets replaced, not how saving gets
        // turned off. The toggle is right there for the other meaning.
        rememberCredential = true
        usingSavedCredential = false
        credentialProblem = nil
        credentialBelongsTo = drive.id
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

    /// Stop waiting on a mount and go back to the credential.
    ///
    /// The engine may already be working, and nothing here can reach into it,
    /// so this gives up watching rather than undoing: a drive that does open
    /// afterwards shows as open on the next look. Better than a spinner with no
    /// way out of it.
    func cancelMount(_ drive: Drive) {
        mountTask?.cancel()
        mountTask = nil
        helperLinesShown = 0
        activeCredential = nil
        failedStage = nil
        statusLines = []
        stageLines = []
        credentialProblem = nil
        phase = .unlock(drive)
    }

    /// Return to the list of drives without ejecting anything.
    ///
    /// Not `start()`: that resumes whatever is already open, which is right on
    /// launch and wrong when the user has asked to see the list.
    func showAllDrives() {
        Task.detached(priority: .userInitiated) {
            let mounts = EngineStatus.current()
            let found = DriveScanner.scan()
            await MainActor.run {
                self.drives = found
                self.openMounts = Dictionary(
                    mounts.map { ($0.devicePath, $0.mountPoint) },
                    uniquingKeysWith: { first, _ in first })
                self.phase = .chooseDrive
            }
        }
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
        // Reload for a different drive, and whenever the field is empty. The
        // second half matters: navigating away clears the value but not this
        // marker, so without it the saved-key banner outlives the key it
        // describes, and Unlock then refuses for want of a credential the
        // interface says it is holding.
        if credentialBelongsTo != drive.id || credential.isEmpty {
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
        notice = nil
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

    func mountPoint(for drive: Drive) -> String? {
        if let direct = openMounts[drive.devicePath] { return direct }
        // A volume inside a container is reported against its logical name —
        // "lvm:<vg>:<disk>:<lv>" — not against the device, so looking the drive
        // up by its device path finds nothing and the row claims to be closed
        // while the drive is plainly open in Finder. The disk is in that
        // identifier, which is what ties the mount back to the drive.
        return openMounts.first { $0.key.contains(drive.id) }?.value
    }

    // MARK: Unlock

    func unlock(_ drive: Drive) {
        credentialProblem = nil
        let raw = credential
        guard !raw.isEmpty else {
            // Whatever the interface was claiming, there is no saved key in
            // hand. Say the true thing before asking for one.
            usingSavedCredential = false
            // Try Again can reach this from the failure screen, where there is
            // no field to show the message next to.
            phase = .unlock(drive)
            credentialProblem =
                drive.kind == .linux
                ? "Enter the drive's passphrase."
                : "Enter the drive's password, or its 48-digit recovery key."
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
                fail(drive, "Could not create a private working folder.", "\(error)")
                return
            }
            workspace = ws

            runMount(drive: drive, credential: normalised)
        }
    }

    /// How much of the helper's transcript has already been shown, so the
    /// final reply can append the remainder instead of repeating all of it.
    private var helperLinesShown = 0
    /// The mount in flight, so waiting on it can be given up.
    private var mountTask: Task<Void, Never>?
    /// The credential of the mount in flight, so its output can be scrubbed of
    /// it before it reaches the screen, the log or a report.
    private var activeCredential: String?

    private func runMount(drive: Drive, credential: String) {
        failedStage = nil
        activeCredential = credential
        let ws: Workspace
        do {
            ws = try Workspace()
        } catch {
            fail(drive, "Could not create a private working folder.", "\(error)")
            return
        }
        workspace = ws

        // With the helper approved, this needs no password at all. Without it,
        // fall back to asking macOS to authorise a single command.
        if helper.isReady {
            appendStatus("Using the background helper — no password needed")
            let aliasPath = (try? ws.makeDeviceAlias(named: drive.name, target: drive.devicePath))?
                .path
            // The helper only replies once, at the end. Without this the steps
            // would show the first one and then jump straight to a mounted
            // drive, which is what the indicator did for the whole time the
            // helper has existed.
            helperLinesShown = 0
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, let text = await self.helper.progress() else { continue }
                    self.showHelperTranscript(text)
                }
            }

            mountTask = Task {
                let outcome = await helper.mount(
                    drive: drive, aliasPath: aliasPath, volume: nil, credential: credential)
                poll.cancel()
                guard let outcome else {
                    // The helper went away; take the ordinary route.
                    self.helper.refresh()
                    self.runMountWithAuthorisation(
                        drive: drive, credential: credential, workspace: ws)
                    return
                }
                self.showHelperTranscript(outcome.transcript)
                if outcome.status == 0,
                    let point = Mounter.discoverMountPoint(
                        for: drive, transcript: outcome.transcript)
                {
                    self.noteVolumeCount(outcome.transcript)
                    self.finishMount(drive: drive, credential: credential, mountPoint: point)
                } else {
                    // The route taken is half the story when something goes
                    // wrong, and it is not in the engine's output.
                    self.appendStatus(
                        "opened through the background helper; it returned status \(outcome.status)"
                    )
                    self.fail(
                        drive,
                        Diagnosis.summarise(outcome.transcript, fallback: ""),
                        outcome.transcript + "\n"
                            + self.statusLines.joined(separator: "\n"))
                }
            }
            return
        }
        runMountWithAuthorisation(drive: drive, credential: credential, workspace: ws)
    }

    /// Find every volume this drive opened.
    ///
    /// A container of several volumes is served as one mount with the others
    /// nested inside it, which only the system mount table can see. A mount the
    /// engine reports itself — as "lvm:<vg>:<disk>:<lv>", which carries the
    /// disk — is the fallback for a drive mounted the ordinary way.
    private func collectVolumes(for drive: Drive, fallback: String) {
        openVolumes = [fallback]
        Task.detached(priority: .userInitiated) {
            let nested = EngineStatus.nestedVolumes(under: fallback)
            let mine =
                nested.isEmpty
                ? EngineStatus.current()
                    .filter { $0.devicePath.contains(drive.id) }
                    .map(\.mountPoint)
                : nested
            await MainActor.run {
                if !mine.isEmpty { self.openVolumes = mine }
            }
        }
    }

    /// Note when a container held more volumes than could be opened.
    private func noteVolumeCount(_ transcript: String) {
        guard
            let line = transcript.components(separatedBy: .newlines)
                .last(where: { $0.contains(MountScript.volumesMarker) }),
            let tail = line.components(separatedBy: MountScript.volumesMarker).last
        else { return }
        let parts = tail.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let opened = Int(parts[0]), let total = Int(parts[1]),
            total > opened
        else { return }
        notice = "This drive holds \(total) volumes and \(opened) could be opened."
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
        collectVolumes(for: drive, fallback: mountPoint)
        self.credential = ""
        credentialBelongsTo = nil
        phase = .mounted(drive, mountPoint)
    }

    private func runMountWithAuthorisation(
        drive: Drive, credential: String, workspace ws: Workspace
    ) {
        // Held like the helper's, so Cancel reaches this route too. Without it
        // the button worked on one path and did nothing on the other, which is
        // worse than not offering it.
        mountTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try Mounter.mount(
                    drive: drive,
                    credential: credential,
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
                    // The label is only knowable now. Remember it so the next
                    // unlock can name the share before mounting.
                    DriveMemory.remember(mountPoint: result.mountPoint, for: drive.uuid)
                    self.openMounts[drive.devicePath] = result.mountPoint
                    self.noteVolumeCount(result.transcript)
                    self.collectVolumes(for: drive, fallback: result.mountPoint)
                    self.phase = .mounted(drive, result.mountPoint)
                }
            } catch let err as EngineError {
                await MainActor.run {
                    if Permissions.isAccessDenied(err.detail ?? "") {
                        self.phase = .needsPermission
                    } else {
                        self.fail(
                            drive,
                            err.errorDescription ?? "The drive could not be opened.",
                            err.detail)
                    }
                }
            } catch {
                await MainActor.run {
                    self.fail(drive, "The drive could not be opened.", "\(error)")
                }
            }
        }
    }

    /// Every route to a failed mount goes through here, so the step the mount
    /// stopped on is recorded in one place instead of at each of the four
    /// sites that can fail.
    private func fail(_ drive: Drive?, _ summary: String, _ detail: String?) {
        failedStage = MountStage.inferred(from: stageLines + statusLines)
        let clean =
            detail
            .map { Diagnostics.redact($0, secret: activeCredential) }
            .map(Diagnostics.withoutMarkers)
        phase = .failed(drive, Diagnostics.redact(summary, secret: activeCredential), clean)
    }

    /// Show whatever of the helper's transcript has not been shown yet.
    private func showHelperTranscript(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > helperLinesShown else { return }
        for line in lines[helperLinesShown...] { appendStatus(line) }
        helperLinesShown = lines.count
    }

    private func appendStatus(_ line: String) {
        // Redact as it arrives: the log is shown in the interface, offered in
        // bug reports, and written to the workspace. Doing it here means there
        // is no window in which a credential-shaped string exists in any of
        // those places.
        statusLines.append(Diagnostics.redact(line, secret: activeCredential))
        // Stage markers drive the indicator; they are not output worth reading.
        if line.contains("LUKOTTA_") { statusLines.removeLast() }
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
        // Every volume this drive opened, so a container of several does not
        // leave the rest mounted behind an ejected one. Volumes nested inside
        // another go with their parent: the engine tears down everything under
        // the mount it owns, and does not recognise the nested points as its.
        var paths = openVolumes
        if !paths.contains(path) { paths.append(path) }
        let roots = paths.filter { point in
            !paths.contains { $0 != point && point.hasPrefix($0 + "/") }
        }
        Task.detached(priority: .userInitiated) {
            let result =
                roots.map { EngineStatus.unmount(mountPoint: $0) }
                .last { !$0.ok } ?? (ok: true, message: "")
            // The generated multi-volume action has served its purpose once the
            // drive is gone; removing it leaves the engine's config as found.
            if result.ok { EngineConfig.removeGeneratedAction() }
            await MainActor.run {
                self.isEjecting = false
                if result.ok {
                    self.openVolumes = []
                    self.openMounts = self.openMounts.filter { !paths.contains($0.value) }
                    // The list, not start(): with a single drive attached that
                    // selects it again and reopens the unlock screen, which is
                    // the opposite of what ejecting asked for.
                    self.credential = ""
                    self.credentialBelongsTo = nil
                    self.credentialProblem = nil
                    self.statusLines = []
                    self.showAllDrives()
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
            EngineConfig.removeGeneratedAction()
            await MainActor.run { completion() }
        }
    }

    /// Remove the private workspace. Called when the app quits so nothing of
    /// this session is left behind.
    func cleanUp() {
        workspace?.destroy()
        workspace = nil
        EngineConfig.removeGeneratedAction()
    }
}
