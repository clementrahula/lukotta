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

    /// What just happened, in a sentence, for anyone who is not watching.
    ///
    /// Unlocking finishes without moving the focus, so a screen reader is given
    /// nothing to read unless it is told. Only the moments worth interrupting
    /// for: a drive that opened, one that did not, and one that started.
    var spokenPhase: String? {
        switch phase {
        case .mounted(let drive, _):
            return String(localized: "“\(drive.name)” is unlocked")
        case .working(let drive):
            return String(localized: "Opening “\(drive.name)”")
        case .failed(_, let summary, _):
            return summary.isEmpty
                ? String(localized: "The drive was not opened")
                : String(localized: "The drive was not opened. \(summary)")
        default: return nil
        }
    }
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
    /// Told when the last drive closes, so an update that was waiting for it can
    /// go ahead.
    var onAllDrivesClosed: (() -> Void)?

    /// How full each open drive is, by mount point, and how many volumes it
    /// opened. Kept current rather than read once: the number people want is
    /// how much room is left now, and copying a file to the drive is exactly
    /// when they look.
    @Published var space: [String: VolumeSpace] = [:]
    @Published var volumeCount: [String: Int] = [:]
    private var spaceTimer: Timer?

    /// Re-read the open drives, and keep doing it while any are open.
    ///
    /// Off the main actor: statfs on a network mount blocks, and a drive that
    /// has stopped answering would otherwise take the interface with it.
    func refreshSpace() {
        let points = Array(openMounts.values)
        guard !points.isEmpty else {
            space = [:]
            volumeCount = [:]
            spaceTimer?.invalidate()
            spaceTimer = nil
            return
        }
        Task.detached(priority: .utility) {
            var found: [String: VolumeSpace] = [:]
            var counts: [String: Int] = [:]
            for point in points {
                if let s = VolumeSpace.of(point) { found[point] = s }
                let nested = EngineStatus.nestedVolumes(under: point)
                counts[point] = max(1, nested.count)
            }
            let readings = found
            let tally = counts
            await MainActor.run {
                self.space = readings
                self.volumeCount = tally
            }
        }
        if spaceTimer == nil {
            // Often enough that a copy in progress is visibly moving, rarely
            // enough that a sleeping drive is not woken for it.
            spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSpace() }
            }
        }
    }
    /// The uninstall in progress, so it can be shown rather than guessed at.
    @Published var isUninstalling = false
    @Published var uninstallSteps: [Uninstall.Step] = []
    @Published var uninstallFinished = false
    @Published var uninstallFailure: String?
    /// Container files opened through File, by the whole disk each was
    /// attached as. They are in the list exactly as long as they are attached,
    /// and ejecting one detaches it and takes it out again.
    @Published private(set) var openedImages: [String: URL] = [:]
    /// A file that could not be opened, and what was found in it.
    @Published var imageProblem: String?

    /// Open an encrypted container that is a file rather than a drive.
    ///
    /// Attached as this user, not by the helper: macOS hands back a device node
    /// and everything after that — the scan, the probe, the mount — is what it
    /// always was. The root helper never learns the file name.
    func openImage(_ url: URL) {
        imageProblem = nil
        Log.drives.notice("opening a disk image")
        Task.detached(priority: .userInitiated) {
            switch DiskImage.attach(url) {
            case .failure(let failure):
                let message: String
                switch failure {
                case .notAnImage(let text), .nothingToOpen(let text): message = text
                }
                Log.drives.error("the image would not attach")
                await MainActor.run { self.imageProblem = message }
            case .success(let attached):
                var found = DriveScanner.scan(images: [attached.identifier])
                var mine = found.filter {
                    DriveScanner.wholeDisk(of: $0.id) == attached.identifier
                }
                // A container made with `cryptsetup luksFormat container.img`
                // has no partition table: it attaches as a whole disk with
                // nothing in it as far as diskutil is concerned, so the scan
                // finds nothing. Its first sector says what it is, and the
                // device belongs to whoever attached it, so it can be read
                // here without troubling the helper.
                if mine.isEmpty, let whole = DiskImage.wholeDiskDrive(attached, url: url) {
                    mine = [whole]
                    found.append(whole)
                }
                guard !mine.isEmpty else {
                    // Attached, and holding nothing this app can open. Put it
                    // back rather than leaving a device attached to nothing.
                    DiskImage.detach(attached.device)
                    Log.drives.notice("the image held nothing openable")
                    await MainActor.run {
                        self.imageProblem = appString(
                            "There is nothing in “\(url.lastPathComponent)” that \(appName) can open. It holds no BitLocker, LUKS, NTFS or Linux volume."
                        )
                    }
                    return
                }
                await MainActor.run {
                    self.openedImages[attached.identifier] = url
                    self.drives = found
                    self.phase = .chooseDrive
                }
            }
        }
    }

    /// Put back any container file whose drive has gone from the list.
    ///
    /// Called after an eject: the volume is down, so the image can be detached
    /// and the file is no longer held open.
    private func detachImagesNoLongerListed() {
        let attached = Set(drives.map { DriveScanner.wholeDisk(of: $0.id) })
        let gone = openedImages.keys.filter { !attached.contains($0) }
        guard !gone.isEmpty else { return }
        for identifier in gone { openedImages[identifier] = nil }
        Task.detached(priority: .utility) {
            for identifier in gone { DiskImage.detach("/dev/" + identifier) }
        }
    }

    /// Which mount is being ejected, so the row that was clicked is the row
    /// that shows it happening. A drive list can have several open at once.
    @Published var ejectingPath: String?
    var isEjecting: Bool { ejectingPath != nil }
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

    /// Look again, off the main thread.
    ///
    /// Called every time the app comes forward: permissions are granted in
    /// System Settings, so the reading goes stale the moment the user leaves.
    /// Reading them on the way back in would mean disk I/O on the main thread
    /// at every switch between applications.
    func refreshPermissions() {
        Task.detached(priority: .utility) {
            let reading = Permissions.reading()
            await MainActor.run { self.applyPermissions(reading) }
        }
    }

    /// Take a reading that was made off the main thread.
    ///
    /// The two probes open files, one of them a SQLite database, so they are
    /// not done here — `start` reads them on the way to scanning and hands the
    /// answer back. `helper.refresh` stays: it asks launchd about a service it
    /// already knows about, and touches no disk.
    func applyPermissions(_ reading: Permissions.Reading) {
        hasFullDiskAccess = reading.fullDiskAccess
        // Prefer the recorded decision; fall back to evidence. Having opened a
        // drive before is proof the permission was granted, and does not depend
        // on an undocumented database schema continuing to look the same.
        removableAccess = reading.removableVolumes ?? (DriveMemory.hasAny ? true : nil)
        helper.refresh()
    }

    private var workspace: Workspace?

    /// Watches for drives arriving and leaving while the app is open.
    private lazy var watcher = DiskWatcher { [weak self] in
        Task { @MainActor in self?.driveSetChanged() }
    }

    /// Watches for the machine sleeping and waking.
    private lazy var sleepWatch = SleepWatch(
        willSleep: { [weak self] in self?.prepareForSleep() },
        didWake: { [weak self] in self?.recoverFromSleep() })

    /// The machine is going to sleep.
    ///
    /// Nothing is unmounted and nothing is asked. The one thing worth doing is
    /// stopping the free-space poll, so the app does not spend the whole of the
    /// wake window starting statfs calls against a mount that cannot answer
    /// yet — each of which would sit in the kernel until it could.
    private func prepareForSleep() {
        Log.sleep.notice("sleeping with \(self.openMounts.count, privacy: .public) mounts open")
        spaceTimer?.invalidate()
        spaceTimer = nil
    }

    /// The machine has woken.
    ///
    /// Everything is expected to still be there, so the aim is to confirm that
    /// quietly and say nothing. The drive list is re-read, because disks can be
    /// attached and removed while the machine is asleep and DiskArbitration does
    /// not report what happened while nobody was listening, and each open mount
    /// is asked whether it is answering until it is — or until the grace period
    /// runs out and the drive really has gone.
    private func recoverFromSleep() {
        Log.sleep.notice("woke with \(self.openMounts.count, privacy: .public) mounts open")
        driveSetChanged()
        let points = Array(openMounts.values)
        guard !points.isEmpty else { return }

        Task.detached(priority: .utility) {
            var elapsed: TimeInterval = 0
            while true {
                let silent = points.filter { !MountProbe.isAnswering($0) }
                if silent.isEmpty {
                    Log.sleep.notice(
                        "every mount answered after \(elapsed, privacy: .public)s")
                    // Back as it was. Nothing is said, because from where the
                    // user is sitting nothing happened.
                    await MainActor.run { self.refreshSpace() }
                    return
                }
                Log.sleep.notice(
                    "\(silent.count, privacy: .public) mounts silent after \(elapsed, privacy: .public)s"
                )
                guard let delay = WakeRecovery.nextDelay(after: elapsed) else { break }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                elapsed += delay
            }
            // Still silent. Either the microVM is gone, in which case the mount
            // is a corpse that has to be cleared before macOS starts asking
            // about a server that will not answer, or it is running and merely
            // slow — and a running one is left alone.
            let live = EngineStatus.current().map(\.mountPoint)
            let dead = points.filter { point in
                !live.contains(point) && !live.contains { point.hasPrefix($0 + "/") }
            }
            guard !dead.isEmpty else {
                // Silent but still running: slow, not gone. Left alone.
                Log.sleep.notice("the engine still reports every mount; leaving them")
                await MainActor.run { self.refreshSpace() }
                return
            }
            Log.sleep.error("\(dead.count, privacy: .public) mounts did not come back")
            for point in EngineStatus.stale() { EngineStatus.forceUnmount(mountPoint: point) }
            await MainActor.run { self.dropMounts(dead) }
        }
    }

    /// Forget mounts that are no longer there, and leave the interface
    /// somewhere it can be used.
    private func dropMounts(_ points: [String]) {
        let names = points.map { ($0 as NSString).lastPathComponent }
        openVolumes = []
        openMounts = openMounts.filter { !points.contains($0.value) }
        space = space.filter { !points.contains($0.key) }
        volumeCount = volumeCount.filter { !points.contains($0.key) }
        if let first = names.first {
            notice =
                names.count > 1
                ? appString(
                    "\(names.count) drives had stopped responding and were disconnected. You can open them again."
                )
                : appString(
                    "“\(first)” had stopped responding and was disconnected. You can open it again."
                )
        }
        if openMounts.isEmpty, case .mounted = phase { phase = .chooseDrive }
        refreshSpace()
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
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            let found = DriveScanner.scan(images: images)
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
                self.refreshSpace()

                guard vanished, let drive = self.currentDrive else { return }
                Log.drives.notice("the drive on screen was unplugged")
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
                self.notice = appString("“\(name)” was disconnected.")
                self.credential = ""
                self.credentialProblem = nil
                self.phase = .chooseDrive
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        watcher.start()
        sleepWatch.start()
        phase = .scanning
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            // First, and off the main thread: both probes read files, and doing
            // that where the interface is drawn stalls the first frame on
            // however long the disk takes to answer.
            let permissions = Permissions.reading()
            let settled = await MainActor.run { () -> Bool in
                self.applyPermissions(permissions)
                Log.app.notice(
                    "starting: full disk access \(self.hasFullDiskAccess, privacy: .public), helper \(String(describing: self.helper.state), privacy: .public)"
                )
                // Far enough to count as a working build: dyld resolved
                // everything, a window is drawn, and the permissions have been
                // read. Whether the user has granted Full Disk Access is not a
                // property of the build — waiting for a drive scan that a
                // machine without the permission never reaches would roll a
                // perfectly good version back after three launches.
                Rollback.confirmHealthy()
                // Say so before any password is typed, rather than after a
                // failed unlock. Full Disk Access cannot be requested, only
                // detected.
                guard self.hasFullDiskAccess else {
                    self.phase = .needsPermission
                    return false
                }
                return true
            }
            guard settled else { return }

            // Before anything is mounted, while the engine's lock can still be
            // had. Declines the moment a drive is open, which is the only time
            // it would matter and the only time it would be unsafe.
            GuestRuntime.syncIfNeeded()

            // Clear anything left mounted by a virtual machine that is no
            // longer running. Until it goes, macOS keeps asking the user about
            // a server that cannot answer, and the drive cannot be opened
            // again because its mount point is still occupied.
            let abandoned = EngineStatus.stale()
            if !abandoned.isEmpty {
                Log.mount.notice(
                    "clearing \(abandoned.count, privacy: .public) mounts left by a microVM that is gone"
                )
            }
            for point in abandoned { EngineStatus.forceUnmount(mountPoint: point) }

            let mounts = EngineStatus.current()
            let found = DriveScanner.scan(images: images)
            await MainActor.run {
                self.drives = found
                if let name = abandoned.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                    self.notice =
                        abandoned.count > 1
                        ? appString(
                            "\(abandoned.count) drives had stopped responding and were disconnected. You can open them again."
                        )
                        : appString(
                            "“\(name)” had stopped responding and was disconnected. You can open it again."
                        )
                }
                self.openMounts = Dictionary(
                    mounts.map { ($0.devicePath, $0.mountPoint) },
                    uniquingKeysWith: { first, _ in first })
                self.refreshSpace()
                // Always the list, even when a drive is already open. The list
                // shows it as open and offers to eject it, so opening straight
                // into one drive only hides the others.
                self.phase = .chooseDrive
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

    /// Set while quitting in order to come straight back.
    ///
    /// Read by the delegate, which starts the replacement only once this copy
    /// has actually gone. Starting it first would leave two copies running if
    /// the quit were turned down.
    nonisolated(unsafe) static var wantsRelaunch = false

    func relaunch() {
        Log.app.notice("relaunching at the user's request")
        AppModel.wantsRelaunch = true
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
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            let mounts = EngineStatus.current()
            let found = DriveScanner.scan(images: images)
            await MainActor.run {
                self.drives = found
                self.openMounts = Dictionary(
                    mounts.map { ($0.devicePath, $0.mountPoint) },
                    uniquingKeysWith: { first, _ in first })
                self.refreshSpace()
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
        identify(drive)
    }

    /// What the chosen partition actually holds, once the helper has read it.
    ///
    /// Only ever set to something worth saying. A drive whose first sector
    /// cannot be read, or that is read as something nobody recognises, leaves
    /// this nil and the screen exactly as it was.
    @Published var chosenFormat: VolumeFormat?

    /// Ask the helper what is on the drive, in the background.
    ///
    /// A Microsoft Basic Data partition is BitLocker, plain NTFS or exFAT and
    /// the partition type does not say which — so until this comes back the
    /// only way to find out has been to type a password and watch it fail.
    /// Linux partitions are left alone: LUKS announces itself in its own
    /// header, and the engine's own probe already reports it.
    private func identify(_ drive: Drive) {
        chosenFormat = nil
        guard drive.kind == .microsoft, helper.isReady else { return }
        let devicePath = drive.devicePath
        let identifier = drive.id
        Task { [weak self] in
            guard let self else { return }
            let format = await self.helper.identify(devicePath: devicePath)
            // The user may have gone somewhere else while the helper read a
            // sector. Answering about a drive nobody is looking at would put a
            // sentence about one drive under the name of another.
            guard case .unlock(let current) = self.phase, current.id == identifier else { return }
            Log.drives.notice("identified as \(format.rawValue, privacy: .public)")
            self.chosenFormat = format == .unknown ? nil : format
        }
    }

    func backToDrives() {
        credential = ""
        credentialProblem = nil
        chosenFormat = nil
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

    /// Whether this drive has already been read and found not to be encrypted.
    ///
    /// The one case where an empty field is the right answer rather than a
    /// missing one.
    var chosenDriveIsOpenAlready: Bool {
        chosenFormat == .ntfs || chosenFormat == .exfat
    }

    func unlock(_ drive: Drive) {
        credentialProblem = nil
        let raw = credential
        // Nothing to unlock: the first sector says it is not encrypted, so the
        // engine mounts it without asking for anything. Sending it on with an
        // empty credential is what makes the screen's own sentence true.
        if raw.isEmpty, chosenDriveIsOpenAlready {
            Log.mount.notice("opening an unencrypted drive, no credential needed")
            statusLines = []
            phase = .working(drive)
            runMount(drive: drive, credential: "")
            return
        }
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
            Log.mount.notice(
                "unlock requested: kind \(String(describing: drive.kind), privacy: .public), helper \(self.helper.isReady, privacy: .public)"
            )
            statusLines = []
            phase = .working(drive)
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
            // drive.
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
        guard parts.count == 2, let opened = Int(parts[0]), let totalCount = Int(parts[1]),
            totalCount > opened
        else { return }
        // One number, not two: a sentence carrying two counts needs both to
        // agree with the noun, and no two languages agree the same way.
        notice = appString(
            "This drive holds \(totalCount) volumes and not all of them could be opened.")
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
        Log.mount.notice("mounted through the helper")
        openMounts[drive.devicePath] = mountPoint
        collectVolumes(for: drive, fallback: mountPoint)
        self.credential = ""
        credentialBelongsTo = nil
        phase = .mounted(drive, mountPoint)
    }

    private func runMountWithAuthorisation(
        drive: Drive, credential: String, workspace ws: Workspace
    ) {
        // Held like the helper's, so Cancel reaches this route too. A button
        // that works on one route and not the other is worse than none.
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
                    Log.mount.notice("mounted without the helper")
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
        // The stage is ours and safe to read back; the summary can carry
        // engine output, so it goes through the same redaction as the report.
        Log.mount.error(
            "mount failed at \(String(describing: self.failedStage), privacy: .public): \(Diagnostics.redact(summary, secret: self.activeCredential))"
        )
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
        // Already going. Ejecting takes seconds, and without this a second
        // click starts a second teardown of the same drive.
        guard ejectingPath == nil else { return }
        ejectingPath = path
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
        Log.mount.notice("ejecting \(roots.count, privacy: .public) mounts")
        Task.detached(priority: .userInitiated) {
            let result =
                roots.map { EngineStatus.unmount(mountPoint: $0) }
                .last { !$0.ok } ?? (ok: true, message: "")
            // The generated multi-volume action has served its purpose once the
            // drive is gone; removing it leaves the engine's config as found.
            if result.ok { EngineConfig.removeGeneratedAction() }
            await MainActor.run {
                self.ejectingPath = nil
                if result.ok {
                    self.openVolumes = []
                    if self.openMounts.isEmpty { self.onAllDrivesClosed?() }
                    self.openMounts = self.openMounts.filter { !paths.contains($0.value) }
                    // The list, not start(): with a single drive attached that
                    // selects it again and reopens the unlock screen, which is
                    // the opposite of what ejecting asked for.
                    self.credential = ""
                    self.credentialBelongsTo = nil
                    self.credentialProblem = nil
                    self.statusLines = []
                    self.showAllDrives()
                    // The volume is down, so a container file that was opened
                    // to reach it can go back to being a file.
                    self.detachImagesNoLongerListed()
                } else {
                    self.ejectProblem = result.message
                }
            }
        }
    }

    /// Eject everything, then run the completion. Used on quit.
    func ejectAll(completion: @escaping @MainActor @Sendable () -> Void) {
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
