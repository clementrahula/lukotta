import SwiftUI
import AppKit

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
        case failed(Drive?, String, String?)   // drive, summary, raw detail
    }

    @Published var phase: Phase = .scanning
    @Published var drives: [Drive] = []
    @Published var credential: String = ""
    @Published var revealCredential = false
    @Published var statusLines: [String] = []
    @Published var credentialProblem: String?
    @Published var isEjecting = false
    @Published var ejectProblem: String?

    private var workspace: Workspace?
    /// Held only between discovering several volumes and the user picking one,
    /// so the second attempt does not ask for the credential again.
    private var pendingCredential: String?

    // MARK: Lifecycle

    func start() {
        phase = .scanning
        Task.detached(priority: .userInitiated) {
            // If a drive is already open - the app was reopened, or a previous
            // session left it mounted - go straight to that state.
            let existing = EngineStatus.current().first
            let found = DriveScanner.scan()
            await MainActor.run {
                self.drives = found
                if let existing {
                    let drive = found.first { $0.devicePath == existing.devicePath }
                        ?? Drive(id: URL(fileURLWithPath: existing.devicePath).lastPathComponent,
                                 devicePath: existing.devicePath,
                                 name: URL(fileURLWithPath: existing.mountPoint).lastPathComponent,
                                 sizeBytes: 0,
                                 connection: "",
                                 kind: .microsoft)
                    self.phase = .mounted(drive, existing.mountPoint)
                } else {
                    self.phase = .chooseDrive
                }
            }
        }
    }

    /// True while a drive is open, so quitting can offer to eject first.
    var hasOpenDrive: Bool { !EngineStatus.current().isEmpty }

    /// Re-probe after the user has changed the setting.
    func recheckPermission() {
        start()
    }

    func openPrivacySettings() {
        Permissions.openFullDiskAccessSettings()
    }

    /// Reveal the app itself so it can be dragged into the Full Disk Access list.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func rescan() {
        ejectProblem = nil
        credential = ""
        credentialProblem = nil
        statusLines = []
        start()
    }

    func choose(_ drive: Drive) {
        credential = ""
        credentialProblem = nil
        phase = .unlock(drive)
    }

    func backToDrives() {
        credential = ""
        credentialProblem = nil
        phase = .chooseDrive
    }

    var credentialHint: String? { Credential.hint(for: credential) }

    // MARK: Unlock

    /// Mount a specific logical volume after the user has chosen it.
    func choose(_ volume: LogicalVolume, on drive: Drive) {
        guard let credential = pendingCredential else {
            phase = .unlock(drive)
            return
        }
        statusLines = []
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
                    self.credential = ""
                    self.pendingCredential = nil
                    self.phase = .mounted(drive, result.mountPoint)
                    NSWorkspace.shared.open(URL(fileURLWithPath: result.mountPoint))
                }
            } catch let err as EngineError {
                await MainActor.run {
                    // Several volumes is a question for the user, not a failure:
                    // keep the credential so picking one does not re-prompt.
                    if case .multipleVolumes(let volumes, _) = err {
                        self.pendingCredential = credential
                        self.credential = ""
                        self.phase = .chooseVolume(drive, volumes)
                        return
                    }
                    self.credential = ""
                    self.pendingCredential = nil
                    if Permissions.isAccessDenied(err.detail ?? "") {
                        self.phase = .needsPermission
                    } else {
                        self.phase = .failed(drive,
                                             err.errorDescription ?? "The drive could not be opened.",
                                             err.detail)
                    }
                }
            } catch {
                await MainActor.run {
                    self.credential = ""
                    self.pendingCredential = nil
                    self.phase = .failed(drive, "The drive could not be opened.", "\(error)")
                }
            }
        }
    }

    private func appendStatus(_ line: String) {
        statusLines.append(line)
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
