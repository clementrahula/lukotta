// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    /// The one the application runs on.
    ///
    /// Started from the window when there is a window, and from the delegate
    /// when the app was opened at login and there is none. Both need the same
    /// instance, and tests and snapshots make their own.
    static let shared = AppModel()

    // MARK: What is on screen

    /// Whether `start()` has already run, since two places can call it.
    private var didStart = false

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
    /// Unlocking finishes without moving the focus, so a screen reader has
    /// nothing to read unless it is told. Announced only for a drive that
    /// opened, one that failed to open, and one that started.
    var spokenPhase: String? {
        switch phase {
        case .mounted(let drive, _):
            return String(localized: "“\(isolated(drive.name))” is unlocked")
        case .working(let drive):
            return String(localized: "Opening “\(isolated(drive.name))”")
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
    /// The recent log, read before anybody asks for it.
    ///
    /// Reading it walks the system's log store and takes seconds. Done when the
    /// report sheet opens, the sheet sat blank for that long, which reads as a
    /// sheet that is broken -- so it is kept here and refreshed in the
    /// background, and the sheet has it the moment it appears.
    @Published var recentLog = ""

    func refreshRecentLog() {
        Task.detached(priority: .utility) { [weak self] in
            let text = Diagnostics.recentLog()
            await MainActor.run { self?.recentLog = text }
        }
    }
    /// Whether to keep this drive's credential in the Keychain. Opt-in.
    @Published var rememberCredential = false
    /// Set when a stored credential was found and filled in, so the interface
    /// can say so rather than showing a field of dots with no explanation.
    @Published var usingSavedCredential = false
    /// Which step a failed mount got to, so the failure can point at it rather
    /// than replacing the steps with a bare sentence.
    @Published var failedStage: MountStage?
    /// Every volume opened for the drive on screen. A container can hold more
    /// than one, and all are opened without asking which.
    @Published var openVolumes: [String] = []
    /// Told when the last drive closes, so an update that was waiting for it can
    /// go ahead.
    var onAllDrivesClosed: (() -> Void)?

    /// How full each open drive is, by mount point, and how many volumes it
    /// opened. Re-read rather than measured once, since the figure is looked at
    /// while files are being copied to the drive.
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
            // One read of the mount table for the whole tick. Asked per drive,
            // this was the app's only perpetual background spawner: a process
            // for every open drive, every five seconds, all of them parsing the
            // same table.
            let table = mountTable()
            for point in points {
                if let s = VolumeSpace.of(point) { found[point] = s }
                let nested = EngineStatus.nestedVolumes(under: point, in: table)
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
            // Frequent enough that a copy in progress moves visibly, and rare
            // enough not to wake a sleeping drive.
            spaceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSpace() }
            }
        }
    }
    /// The uninstall in progress, so its state can be shown.
    @Published var isUninstalling = false
    @Published var uninstallSteps: [Uninstall.Step] = []
    @Published var uninstallFinished = false
    @Published var uninstallFailure: String?
    /// Container files opened through File, by the whole disk each was
    /// attached as. They are in the list exactly as long as they are attached,
    /// and ejecting one detaches it and takes it out again.
    @Published private(set) var openedImages: [String: URL] = [:]

    /// A drive that has just left the list, shown where it was.
    ///
    /// At the top of the screen the message displaced everything below it,
    /// which is easy to miss and disruptive at the moment something disappears.
    /// In the row's own place it occupies the space the drive occupied.
    struct Departed: Identifiable, Equatable {
        public let id: String
        let name: String
        /// Where in the list it was, so the message stands in for it.
        let index: Int
    }

    @Published private(set) var departed: [Departed] = []
    private var departedTimer: Timer?

    /// How long the message stays: long enough to read twice, short enough not
    /// to become part of the layout. Nothing waits on it.
    static let departedLingers: TimeInterval = 8

    /// Every disk attached, for the Open Drive sheet.
    @Published var survey: [DriveSurvey.Entry] = []
    @Published var showOpenDrive = false

    /// Survey every disk, including those this app will not open.
    func surveyDrives() {
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            let plist = DriveSurvey.diskutilList()
            let table = mountTable()
            let openable = DriveScanner.scan(images: images)
            let entries = DriveSurvey.survey(
                list: plist, info: { DriveScanner.info(for: $0) ?? [:] },
                mountTable: table, openable: openable)
            await MainActor.run { self.survey = entries }
        }
    }

    /// Give the drive to macOS, and say so rather than appearing to do nothing.
    ///
    /// Silence would be its own surprise: the file was opened, and something
    /// opened it, but not this application. The sheet therefore states what
    /// happened, why, and where the volume went.
    private func handToMacOS(_ drive: Drive) {
        let identifier = DriveScanner.wholeDisk(of: drive.id)
        let file = openedImages[identifier]
        let device = "/dev/" + identifier
        Log.drives.notice("handing the drive to macOS; it reads this format itself")

        Task { [weak self] in
            let point = await Task.detached(priority: .userInitiated) {
                DiskImage.handToMacOS(device: device)
            }.value
            guard let self else { return }

            // It belongs to macOS now, so this app stops holding it. Not
            // detached: detaching would take away the volume just mounted.
            self.openedImages[identifier] = nil
            self.imageDrives[identifier] = nil
            self.drives.removeAll { $0.id == drive.id }
            self.phase = .chooseDrive

            guard let file else { return }
            guard let point else {
                self.imageOpening = .failed(
                    file,
                    appString(
                        "macOS reads this format itself. It did not mount this image, which may already be open in Finder."
                    ))
                return
            }
            self.imageOpening = .handedToMacOS(file, point)
        }
    }

    /// For the snapshots, which need this state without a drive going away.
    func showDeparted(name: String, index: Int) {
        departed = [Departed(id: "snapshot", name: name, index: index)]
    }

    private func noteDeparted(_ drive: Drive) {
        let index = drives.firstIndex { $0.id == drive.id } ?? drives.count
        departed.removeAll { $0.id == drive.id }
        departed.append(Departed(id: drive.id, name: drive.name, index: index))
        departedTimer?.invalidate()
        departedTimer = Timer.scheduledTimer(
            withTimeInterval: Self.departedLingers, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation { self.departed = [] }
                self.departedTimer = nil
            }
        }
    }

    // MARK: Disk images

    /// The rows standing in for container files that hold no partition table.
    ///
    /// `diskutil` reports such a disk as empty, so no scan returns it. The entry
    /// is made once, from the first sector, and reinserted whenever the list is
    /// rebuilt. Without that the row disappeared on the next refresh and the app
    /// announced the drive as disconnected while its mount was still serving.
    private var imageDrives: [String: Drive] = [:]

    /// Container files the engine reads itself, by drive id. Nothing is
    /// attached for these, so nothing is detached: closing one is forgetting it.
    private var engineReadDrives: [String: Drive] = [:]

    /// Which container each opened image is, by drive id.
    ///
    /// What may be done with an image depends on it: a VHDX is read and never
    /// written, and the rest are written by drivers built for this application.
    /// The screen that offers to open one says so.
    var containerFormats: [String: ContainerFormat] = [:]

    /// What the engine already said is inside the file being opened, so the
    /// first-sector probe is not asked about a container it cannot see into.
    private var knownFormat: VolumeFormat?

    /// A scan's results, with the container rows reinserted and those whose
    /// device has gone removed.
    ///
    /// A container detached in Finder, or unplugged with the drive it lived on,
    /// should leave the list like anything else. Merging without this would
    /// keep a row for a file that is not there any more.
    private func reconcileImages(_ found: [Drive], attachments: [String: String]?) -> [Drive] {
        // Nothing is attached for a qcow2, so nothing reports whether it is
        // still present. It stays listed until it is ejected.
        let engineRead = engineReadDrives.values.filter { drive in
            !found.contains { $0.uuid == drive.uuid }
        }
        // What each device name means at this moment. A name is handed back out
        // as soon as it is free, so "disk6" is not a lasting way to refer to a
        // file: checking only that /dev/disk6 exists said an image was still
        // there when what was there was a different image altogether.
        //
        // Nil means hdiutil could not be asked, which says nothing about what
        // is attached; the list is left as it was rather than emptied.
        if let attachments {
            for (identifier, url) in openedImages where attachments[identifier] != url.path {
                Log.drives.notice("a container file is no longer attached")
                openedImages[identifier] = nil
                imageDrives[identifier] = nil
                forget(under: identifier)
            }
        }
        return ImageList.merge(found: found, images: imageDrives) + engineRead
    }

    /// Drop everything read from a disk that has gone.
    ///
    /// What was found on a drive is remembered under the name of the device it
    /// was found on, and that name goes to the next image to be attached. Left
    /// behind, it describes the wrong file: a row saying Btrfs for a container
    /// nothing has looked inside yet.
    private func forget(under identifier: String) {
        containerFormats[identifier] = nil
        for key in knownFormats.keys where DriveScanner.wholeDisk(of: key) == identifier {
            knownFormats[key] = nil
        }
        for key in knownFilesystems.keys where DriveScanner.wholeDisk(of: key) == identifier {
            knownFilesystems[key] = nil
        }
    }

    /// What a row is, as against what it is called this time round.
    ///
    /// A device identifier is temporary and is reused. An image is the file it
    /// was opened from, a partition inside one is that file and which partition
    /// it is, and everything else is the volume's own UUID or the stable name
    /// the scanner makes for a partition table carrying none.
    private func rowKey(_ drive: Drive) -> String {
        let whole = DriveScanner.wholeDisk(of: drive.id)
        if let file = openedImages[whole] {
            return file.path + "#" + drive.id.dropFirst(whole.count)
        }
        return drive.uuid.isEmpty ? drive.id : drive.uuid
    }

    /// The order rows are shown in: the order they arrived.
    ///
    /// The list used to be whatever a scan and two dictionaries happened to
    /// produce, and a dictionary has no order at all. So opening a second image
    /// moved the first one, a drive plugged in third arrived somewhere in the
    /// middle, and rows changed places on every refresh with nothing having
    /// happened. A row now keeps its place for as long as it is there, and
    /// anything new goes to the bottom -- a drive and a file alike, there being
    /// one list and not two.
    private var listOrder = DriveOrder(remembering: ListOrderMemory.read())

    private func inArrivalOrder(_ drives: [Drive]) -> [Drive] {
        let ordered = listOrder.apply(drives) { self.rowKey($0) }
        ListOrderMemory.write(listOrder.remembered)
        return ordered
    }

    /// Somebody dragged a row somewhere else.
    ///
    /// The order they leave it in is theirs, and it outlives the rows: unplug a
    /// drive, quit, come back, and it returns to the place they gave it.
    func moveDrives(from source: IndexSet, to destination: Int) {
        var moved = drives
        moved.move(fromOffsets: source, toOffset: destination)
        drives = moved
        listOrder.adopt(moved.map { self.rowKey($0) })
        ListOrderMemory.write(listOrder.remembered)
    }
    /// Opening a container file, while it is happening and if it fails.
    ///
    /// Attaching takes a moment, and much longer for a file on a share that has
    /// gone away, during which the window had nothing to show. It is a sheet
    /// rather than a row in the list because it answers something the person
    /// just did, and because a failure needs somewhere to be read and
    /// dismissed.
    enum ImageOpening: Equatable, Identifiable {
        case opening(URL)
        case failed(URL, String)
        /// macOS opened it instead, and where it put it.
        case handedToMacOS(URL, String)

        /// The file alone: going from opening to failed then keeps the same
        /// sheet and changes its contents. Including the state would make them
        /// two sheets, the first dismissed and the second presented, which
        /// flickers at the moment a failure is being reported.
        var id: String { url.path }

        var url: URL {
            switch self {
            case .opening(let url), .failed(let url, _), .handedToMacOS(let url, _):
                return url
            }
        }
    }

    @Published var imageOpening: ImageOpening?
    private var imageTask: Task<Void, Never>?

    /// Stop trying, and put back anything that was attached in the meantime.
    func cancelImageOpen() {
        Log.drives.notice("opening a disk image was cancelled")
        imageTask?.cancel()
        imageTask = nil
        imageOpening = nil
    }

    /// Dismiss a failure without trying again.
    func dismissImageProblem() {
        imageOpening = nil
    }

    /// Open an encrypted container that is a file rather than a drive.
    ///
    /// Attached as this user rather than by the helper. macOS hands back a
    /// device node, and the scan, the probe and the mount then proceed as they
    /// do for any drive. The root helper never learns the file name.
    func openImage(_ url: URL) {
        imageTask?.cancel()
        imageOpening = .opening(url)
        Log.drives.notice("opening a disk image")
        let alreadyOpen = Set(openedImages.keys)
        imageTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.attachAndList(url, alreadyOpen: alreadyOpen)
            }.value

            // Cancelled while it ran. Whatever attached is detached again,
            // since nothing will be shown for it.
            guard !Task.isCancelled else {
                if case .success(let attached, _, _) = outcome {
                    DiskImage.detach(attached.device)
                }
                return
            }

            switch outcome {
            case .failure(let message):
                Log.drives.error("the image could not be opened")
                self.imageOpening = .failed(url, message)
            case .qcow2(let drive, let format, let container):
                Log.drives.notice(
                    "image read by the engine: \(container.rawValue, privacy: .public) holding \(format.rawValue, privacy: .public)"
                )
                self.engineReadDrives[drive.id] = drive
                self.drives = self.inArrivalOrder(self.drives + [drive])
                self.imageOpening = nil
                self.knownFormat = format
                // The engine looked inside the file before anything was shown,
                // so the row can say what is in it instead of naming the two
                // things a Linux partition might be. An unencrypted VDI holding
                // Btrfs was listed as LUKS.
                if format != .unknown { self.knownFormats[drive.id] = format }
                self.containerFormats[drive.id] = container
                self.choose(drive)
            case .success(let attached, let all, let mine):
                self.openedImages[attached.identifier] = url
                self.containerFormats[attached.identifier] = .raw
                // Only when the scan could not see it for itself.
                if let synthesised = all.first(where: {
                    $0.id == attached.identifier && $0.uuid == url.path
                }) {
                    self.imageDrives[attached.identifier] = synthesised
                }
                self.drives = self.inArrivalOrder(
                    self.reconcileImages(all, attachments: nil))
                // Opening a file is already the choice, there being nothing to
                // pick from, so it either opens or asks for its passphrase.
                // An image carrying a partition table has a row per volume and
                // none of them is the file, so the first of them is the one
                // that was asked for.
                if let chosen = all.first(where: { $0.uuid == url.path }) ?? mine.first {
                    self.choose(chosen)
                } else {
                    self.phase = .chooseDrive
                }
                // Nothing to read and nothing to dismiss: the drive appearing
                // in the list is the answer.
                self.imageOpening = nil
            }
            self.imageTask = nil
        }
    }

    /// A container the engine reads for itself: qcow2 or VMDK.
    ///
    /// Nothing is attached, because macOS cannot read either. The engine's own
    /// listing is the only account of what the file contains, since no sector
    /// read here sees past the container's mapping.
    private nonisolated static func engineRead(_ url: URL, as container: ContainerFormat)
        -> ImageOutcome
    {
        // Carried through to the screen that offers to open it: what may be
        // done with an image depends on which container it is.
        let types = DiskImage.contents(of: url)
        let format = DiskImage.format(fromTypes: types)

        // Encryption inside a container is opened only by an engine carrying
        // the vmproxy patch. Without it the host probes the file far enough to
        // list what it holds, and the guest is handed "crypto_LUKS" as though it
        // were a filesystem. Reported here rather than failing three screens
        // later.
        if format.isEncrypted, !EnginePaths.opensEncryptionInsideImages {
            return .failure(
                appString(
                    "“\(isolated(url.lastPathComponent))” holds an encrypted volume, and this build’s drive engine cannot open encryption inside an image. Opening the drive it was made from would work."
                ))
        }
        guard !types.isEmpty else {
            return .failure(
                appString(
                    "There is nothing in “\(isolated(url.lastPathComponent))” that \(appName) can open."
                ))
        }
        let linux =
            format == .luks
            || types.contains { $0.hasPrefix("ext") || $0 == "btrfs" || $0 == "xfs" }
        let drive = Drive(
            id: url.lastPathComponent,
            // The engine takes the file itself as the disk to open, by a path
            // it can read all of.
            devicePath: DiskImage.withoutSpaces(url).path,
            name: url.deletingPathExtension().lastPathComponent,
            sizeBytes: fileSize(atPath: url.path),
            // Which container it is, rather than the bare word "image". The
            // engine has already read the file, so there is no reason for the
            // row to be vaguer about it than the app is.
            connection: container.name,
            kind: linux ? .linux : .microsoft,
            uuid: url.path)
        return .qcow2(drive, format, container)
    }

    private enum ImageOutcome {
        case success(DiskImage.Attached, [Drive], [Drive])
        /// Read by the engine rather than attached, so there is no device and
        /// nothing to detach afterwards.
        case qcow2(Drive, VolumeFormat, ContainerFormat)
        case failure(String)
    }

    /// The part that blocks: attach, look, and put it back if there is nothing
    /// in it. Off the main actor, and knows nothing about the interface.
    private nonisolated static func attachAndList(_ url: URL, alreadyOpen: Set<String>)
        -> ImageOutcome
    {
        // A fixed VHD is the raw disk with a footer after it, so the engine
        // opens it unchanged: every structure lies at its natural offset and the
        // last sector is past the end of the disk. The other forms are not raw
        // and are refused by name.
        if DiskImage.isVhd(url) {
            if let objection = DiskImage.objection(toVhd: url) {
                Log.drives.error("refused a VHD")
                return .failure(objection)
            }
            return engineRead(url, as: .vhd)
        }

        // A VHDX shares its name with a VHD and none of its layout: two
        // headers, a region table, a metadata region and an allocation table.
        // The engine's VHDX driver reads it, or it is refused.
        if DiskImage.isVhdx(url) {
            if let objection = DiskImage.objection(toVhdx: url) {
                Log.drives.error("refused a VHDX")
                return .failure(objection)
            }
            return engineRead(url, as: .vhdx)
        }

        // A VDI is never raw at any offset: the header comes first and the
        // blocks follow in the order they were written. The engine's VDI driver
        // reads it, or it is refused.
        if DiskImage.isVdi(url) {
            if let objection = DiskImage.objection(toVdi: url) {
                Log.drives.error("refused a VDI")
                return .failure(objection)
            }
            return engineRead(url, as: .vdi)
        }

        // A VMDK is never attached either: macOS cannot read one and the
        // engine can. In its flat form it always names a separate file for its
        // data, the descriptor being read whole and capped at two megabytes.
        // The rule is therefore that it names only what sits beside it.
        if DiskImage.isVmdk(url) {
            if let objection = DiskImage.objection(toVmdk: url) {
                Log.drives.error("refused a VMDK")
                return .failure(objection)
            }
            // The streamed form is read and not written, and the extension
            // does not say which form it is: the header does.
            return engineRead(url, as: DiskImage.isStreamedVmdk(url) ? .vmdkStreamed : .vmdk)
        }

        // A qcow2 is never attached. macOS cannot read one and the engine can,
        // so the path is handed over. A container file needs no privilege, so
        // that path reaches only a process running as the user who chose it.
        if DiskImage.isQcow2(url) {
            // Checked before the engine is told anything. libkrun opens
            // whatever an image names, a backing file or an external data file,
            // so an image could otherwise determine which other files the
            // virtual machine reads.
            if let objection = DiskImage.objection(toQcow2: url) {
                Log.drives.error("refused an image that names another file")
                return .failure(objection)
            }
            return engineRead(url, as: .qcow2)
        }

        switch DiskImage.attach(url) {
        case .failure(let failure):
            switch failure {
            case .notAnImage(let text), .nothingToOpen(let text): return .failure(text)
            }
        case .success(let attached):
            // Every image, not just this one. Scanning for the new file alone
            // returned a list with no row for any image already open, and the
            // one somebody opened first vanished from the screen until the next
            // refresh put it back somewhere else.
            var all = DriveScanner.scan(images: alreadyOpen.union([attached.identifier]))
            var mine = all.filter { DriveScanner.wholeDisk(of: $0.id) == attached.identifier }
            // A container made with `cryptsetup luksFormat container.img` has
            // no partition table: it is one volume filling the whole disk. The
            // scan offers such a disk now -- it had to, an encrypted stick
            // written the same way being invisible otherwise -- and the row it
            // makes is named after the device the file happens to have landed
            // on. That is not a name for a file: it belongs to the next image
            // as soon as this one is put back, and it is not what a passphrase
            // is saved under.
            //
            // So where the only row for this image is the disk itself, the row
            // built from the file replaces it. Its first sector identifies it,
            // and the device belongs to whoever attached it, so it can be read
            // here without the helper.
            if mine.count <= 1, mine.first.map({ $0.id == attached.identifier }) ?? true,
                let whole = DiskImage.wholeDiskDrive(attached, url: url)
            {
                all.removeAll { $0.id == attached.identifier }
                all.append(whole)
                mine = [whole]
            }
            guard !mine.isEmpty else {
                DiskImage.detach(attached.device)
                Log.drives.notice("the image held nothing openable")
                return .failure(
                    appString(
                        "There is nothing in “\(isolated(url.lastPathComponent))” that \(appName) can open."
                    ))
            }
            return .success(attached, all, mine)
        }
    }

    /// Put back any container file whose drive has gone from the list.
    ///
    /// Called after an eject, with the device paths whose mounts have gone.
    /// The volume is down, so the file can go back to being a file.
    ///
    /// Driven by what was ejected rather than by what is absent from the list.
    /// A container that has been opened and not yet mounted is absent from
    /// nothing, and detaching it because another drive was ejected would remove
    /// it from under whoever just opened it.
    /// Forget a container the engine read for itself. There is no device to
    /// detach; closing it means no longer listing it.
    private func forgetEngineRead(_ paths: [String]) {
        let gone = engineReadDrives.filter { paths.contains($0.value.devicePath) }.map(\.key)
        for id in gone { engineReadDrives[id] = nil }
        if !gone.isEmpty {
            drives.removeAll { gone.contains($0.id) }
            Log.drives.notice("closed \(gone.count, privacy: .public) engine-read containers")
        }
    }

    private func detachImages(forDevices devices: [String]) {
        let gone = ImageList.detaching(devices: devices, images: Set(openedImages.keys))
        guard !gone.isEmpty else { return }
        for identifier in gone {
            openedImages[identifier] = nil
            imageDrives[identifier] = nil
            forget(under: identifier)
        }
        Log.drives.notice("detaching \(gone.count, privacy: .public) container files")
        Task.detached(priority: .utility) {
            for identifier in gone { DiskImage.detach("/dev/" + identifier) }
        }
    }

    // MARK: Permissions and the helper

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

    /// True when nothing is outstanding. The panel's summary reads from this,
    /// so it cannot report everything granted while something is missing.
    var allPermissionsSettled: Bool {
        hasFullDiskAccess && helper.isReady
    }

    /// Look again, off the main thread.
    ///
    /// Called whenever the app comes forward, since permissions are granted in
    /// System Settings and the reading goes stale as soon as the app is left.
    /// Reading them on the way back in would put disk I/O on the main thread at
    /// every switch between applications.
    func refreshPermissions() {
        Task.detached(priority: .utility) {
            let reading = Permissions.reading()
            await MainActor.run { self.applyPermissions(reading) }
        }
    }

    /// Take a reading that was made off the main thread.
    ///
    /// The two probes open files, one of them a SQLite database, so they are not
    /// done here: `start` reads them on the way to scanning and passes the answer
    /// back. `helper.refresh` remains, asking launchd about a service it already
    /// knows and touching no disk.
    func applyPermissions(_ reading: Permissions.Reading) {
        // Granted since, so the screen has nothing left to explain.
        if reading.fullDiskAccess { restoreBlocked = false }
        hasFullDiskAccess = reading.fullDiskAccess
        // The recorded decision first, then the evidence. Having opened a drive
        // before establishes that the permission was granted without depending
        // on an undocumented database schema.
        removableAccess = reading.removableVolumes ?? (DriveMemory.hasAny ? true : nil)
        helper.refresh()
    }

    private var workspace: Workspace?
    /// The workspaces earlier mounts were given.
    ///
    /// A mount that has been given up on can still have work of its own in
    /// flight, holding the workspace it was started with, so the folder cannot
    /// be removed the moment the next mount replaces it. Keeping them here
    /// means quitting removes all of them; before, quitting removed the last
    /// one and left the rest in the temporary folder until macOS got round to
    /// it, each holding that mount's log.
    private var pastWorkspaces: [Workspace] = []

    /// Watches for drives arriving and leaving while the app is open.
    private lazy var watcher = DiskWatcher { [weak self] in
        Task { @MainActor [weak self] in self?.driveSetChanged() }
    }

    // MARK: Sleeping and waking

    /// Watches for the machine sleeping and waking.
    private lazy var sleepWatch = SleepWatch(
        willSleep: { [weak self] in self?.prepareForSleep() },
        didWake: { [weak self] in self?.recoverFromSleep() })

    /// The machine is going to sleep.
    ///
    /// Nothing is unmounted and nothing is asked. The free-space poll stops, so
    /// that the wake window is not spent issuing statfs calls against a mount
    /// that cannot answer yet, each of which would block in the kernel.
    private func prepareForSleep() {
        Log.sleep.notice("sleeping with \(self.openMounts.count, privacy: .public) mounts open")
        spaceTimer?.invalidate()
        spaceTimer = nil
    }

    /// The machine has woken.
    ///
    /// Everything is expected to still be there, and confirming it silently is
    /// the whole of the work. The drive list is re-read, since disks can be
    /// attached and removed while the machine sleeps and DiskArbitration reports
    /// nothing that happened while nobody was listening. Each open mount is then
    /// asked whether it answers, until it does or the grace period expires and
    /// the drive has genuinely gone.
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
                    // Back as it was, and nothing is reported: from the
                    // person's side nothing happened.
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
            // Still silent. Either the microVM has gone, in which case the
            // mount must be cleared before macOS begins asking about a server
            // that will not answer, or it is running and slow, and a running one
            // is left alone.
            let live = EngineStatus.current().map(\.mountPoint)
            let dead = points.filter { point in
                !live.contains(point) && !live.contains { point.hasPrefix($0 + "/") }
            }
            guard !dead.isEmpty else {
                // Silent and still running: slow rather than gone.
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
        readOnlyMounts.subtract(points)
        // Nothing is forgotten here. These mounts went away without anybody
        // ejecting them: the drive was unplugged, or the Mac slept through it.
        // Plugged in again, it is one to open again.
        space = space.filter { !points.contains($0.key) }
        volumeCount = volumeCount.filter { !points.contains($0.key) }
        if let sentence = stoppedRespondingNotice(names) { notice = sentence }
        if openMounts.isEmpty, case .mounted = phase { phase = .chooseDrive }
        refreshSpace()
    }

    // MARK: Scanning

    /// The drive on screen, whichever way it is being shown.
    private var currentDrive: Drive? {
        switch phase {
        case .unlock(let drive), .working(let drive), .mounted(let drive, _): return drive
        default: return nil
        }
    }

    /// A drive was plugged in or pulled out.
    ///
    /// Refreshes the list in place. A drive being looked at that has gone away
    /// is worth interrupting for, the alternative being a screen offering to
    /// unlock something no longer attached, or reporting a drive as open after
    /// it was pulled out from under the mount.
    /// Take the result of a scan and make it what the interface shows.
    ///
    /// The three callers differ in what they do afterwards, not in this: the
    /// list, the generation that tells a waiting test a scan was applied, the
    /// open mounts, and the space they have left.
    private func applyScan(_ sighting: Sighting) -> [Drive] {
        let listed = inArrivalOrder(
            reconcileImages(sighting.found, attachments: sighting.attachments))
        drives = listed
        scanGeneration += 1
        openMounts = Dictionary(
            sighting.mounts.map { ($0.devicePath, $0.mountPoint) },
            uniquingKeysWith: { first, _ in first })
        refreshSpace()
        return listed
    }

    /// One look at the machine: what is attached, what is mounted, and which
    /// file each attached disk came from.
    ///
    /// Taken together and off the main thread. Asking for the three separately
    /// meant they could disagree -- a scan begun before a file finished opening
    /// carried a set of images that did not include it, and the drive somebody
    /// had just opened was declared unplugged.
    struct Sighting: Sendable {
        var found: [Drive]
        var mounts: [EngineMount]
        var attachments: [String: String]?
    }

    private nonisolated static func look(for images: Set<String>) -> Sighting {
        Sighting(
            found: DriveScanner.scan(images: images),
            mounts: EngineStatus.current(),
            attachments: DiskImage.attachments())
    }

    /// What to say when mounts went away without anybody ejecting them.
    private func stoppedRespondingNotice(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count > 1
            ? appString(
                "\(names.count) drives had stopped responding and were disconnected. You can open them again."
            )
            : appString(
                "“\(isolated(first))” had stopped responding and was disconnected. You can open it again."
            )
    }

    private func driveSetChanged() {
        // The Open Drive sheet lists the same disks and must not go stale
        // behind its own window: a drive unplugged while it is up sat there as
        // though it were still there.
        if showOpenDrive { surveyDrives() }
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            let sighting = Self.look(for: images)
            await MainActor.run {
                let listed = self.applyScan(sighting)
                // Judged against the list as it will be shown rather than the
                // raw scan. A container with no partition table appears in the
                // first and not the second, and judging by the scan alone called
                // it unplugged on the next refresh, returning the person to the
                // list from a drive they had just opened.
                let vanished =
                    self.currentDrive.map { drive in
                        !listed.contains { $0.devicePath == drive.devicePath }
                    } ?? false

                // A drive that was open before the restart, plugged in now.
                self.restoreRememberedMounts()

                guard vanished, let drive = self.currentDrive else { return }
                Log.drives.notice("the drive on screen was unplugged")
                // Whatever was mounted from it cannot be reached any more, and
                // leaving the mount behind is what makes macOS ask about a
                // server that will never answer.
                Task.detached(priority: .userInitiated) {
                    for point in EngineStatus.stale() {
                        EngineStatus.forceUnmount(mountPoint: point)
                    }
                }
                self.openVolumes = []
                self.openMounts = self.openMounts.filter { !drive.owns($0.key) }
                self.noteDeparted(drive)
                self.credential = ""
                self.credentialProblem = nil
                self.phase = .chooseDrive
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        watcher.start()
        sleepWatch.start()
        putBackWhatWasLeftAttached()
        // An app update replaces the binary inside the bundle and leaves the
        // running daemon alone, so a fix to the mount can land and change
        // nothing at all.
        helper.replaceIfStale()
        // Read now, so the report sheet is filled in before anybody asks for
        // it rather than several seconds after.
        refreshRecentLog()
        phase = .scanning
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            // A run that ended badly, or a machine that slept through one, can
            // leave the engine's network helper behind with nothing to eject it.
            // Taken down here rather than left to accumulate, since one of them
            // holds a lock on the image file it was opened from.
            EngineProcesses.tidyLeftovers()

            // Off the main thread and before anything else: both probes read
            // files, and doing that where the interface is drawn holds the first
            // frame for as long as the disk takes to answer.
            let permissions = Permissions.reading()
            let settled = await MainActor.run { () -> Bool in
                self.applyPermissions(permissions)
                Log.app.notice(
                    "starting: full disk access \(self.hasFullDiskAccess, privacy: .public), helper \(String(describing: self.helper.state), privacy: .public)"
                )
                // Far enough to establish a working build: dyld resolved
                // everything, a window is drawn, and the permissions have been
                // read. Full Disk Access is a property of the machine rather
                // than the build, and waiting for a drive scan that a machine
                // without the permission never reaches would roll back a sound
                // version after three launches.
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

            // Before anything is mounted, while the engine's lock is still
            // available. It declines once a drive is open, which is both when it
            // would matter and when it would be unsafe.
            GuestRuntime.syncIfNeeded()

            // Clear anything left mounted by a virtual machine that is no
            // longer running. Until it is cleared, macOS keeps asking about a
            // server that cannot answer, and the drive cannot be opened again
            // while its mount point is occupied.
            let abandoned = EngineStatus.stale()
            if !abandoned.isEmpty {
                Log.mount.notice(
                    "clearing \(abandoned.count, privacy: .public) mounts left by a microVM that is gone"
                )
            }
            for point in abandoned { EngineStatus.forceUnmount(mountPoint: point) }

            let sighting = Self.look(for: images)
            await MainActor.run {
                _ = self.applyScan(sighting)
                let names = abandoned.map { URL(fileURLWithPath: $0).lastPathComponent }
                if let sentence = self.stoppedRespondingNotice(names) { self.notice = sentence }
                // Always the list, even when a drive is already open. The list
                // shows it as open and offers to eject it, whereas opening
                // straight into one drive hides the others.
                self.phase = .chooseDrive
            }
        }
    }

    /// True while a drive is open, so quitting can offer to eject first.
    ///
    /// Reads cached state rather than spawning the engine. It is consulted on
    /// the main thread during a quit, where a subprocess would stall the app.
    var hasOpenDrive: Bool { !openMounts.isEmpty }

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

    /// Anything this app attached and did not put back.
    ///
    /// A crash, a forced quit, or a device that would not let go at the time
    /// leaves a container attached. It then turns up in the list as a disk with
    /// no name and no explanation, which is nobody's idea of a drive. Nothing
    /// is said about it: attaching is this app's business, and putting it back
    /// is too.
    ///
    /// Only what this app itself attached, and only what is not in use.
    private func putBackWhatWasLeftAttached() {
        Task.detached(priority: .utility) {
            let stale = DiskImage.strayAttachments()
            guard !stale.isEmpty else { return }
            Log.drives.notice(
                "putting back \(stale.count, privacy: .public) containers left attached")
            for device in stale { DiskImage.detach(device) }
        }
    }

    /// What this app remembers a drive by.    /// What this app remembers a drive by.
    ///
    /// A container file is the file, wherever it is attached and whatever the
    /// device is called this time: attaching gives it a fresh device
    /// identifier every time, so a passphrase saved for one attachment was
    /// looked for under a name that no longer existed. The path is the thing
    /// that does not change.
    ///
    /// Everything else is the volume's own UUID, or the stable name the
    /// scanner makes for a partition table that carries none.
    func identity(of drive: Drive) -> String {
        if let file = openedImages[DriveScanner.wholeDisk(of: drive.id)] { return file.path }
        if let file = engineReadDrives[drive.id] { return file.uuid }
        // A partition table carrying no UUID at all leaves nothing to tell one
        // drive from another, and an empty string would make every such drive
        // the same drive. The device name is at least this drive, now.
        return drive.uuid.isEmpty ? drive.id : drive.uuid
    }

    /// Discard a stored credential and return to entering one.    /// Discard a stored credential and return to entering one.
    func forgetSavedCredential(for drive: Drive) {
        CredentialStore.delete(for: identity(of: drive))
        credential = ""
        // Left on. Forgetting replaces a key; the toggle turns saving off.
        rememberCredential = true
        usingSavedCredential = false
        credentialProblem = nil
        credentialBelongsTo = identity(of: drive)
    }

    func openFilesAndFoldersSettings() {
        Permissions.openFilesAndFoldersSettings()
    }

    func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stop waiting on a mount and go back to the credential.
    ///
    /// The engine may already be working and nothing here can reach into it, so
    /// this stops watching rather than undoing. A drive that opens afterwards
    /// shows as open at the next look, which is preferable to a spinner with no
    /// way out.
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
    /// Not `start()`, which resumes whatever is already open. That is correct on
    /// launch and wrong when the list has been asked for.
    func showAllDrives() {
        choiceGeneration += 1
        let images = Set(openedImages.keys)
        Task.detached(priority: .userInitiated) {
            let sighting = Self.look(for: images)
            await MainActor.run {
                _ = self.applyScan(sighting)
                self.phase = .chooseDrive
            }
        }
    }

    /// Whether the app is on its opening scan.
    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// Bumped every time a scan's results are applied.
    ///
    /// A rebuild does not change the phase, the drive on screen staying on
    /// screen, so nothing else records that one has happened. A test waiting on
    /// the phase would pass straight through and assert against the list as it
    /// was before.
    @Published private(set) var scanGeneration = 0

    /// Rebuild the list without touching anything else: what a drive appearing
    /// or disappearing triggers, reachable from a test.
    func refreshDrives() {
        driveSetChanged()
    }

    func rescan() {
        choiceGeneration += 1
        ejectProblem = nil
        credentialBelongsTo = nil
        credential = ""
        credentialProblem = nil
        statusLines = []
        start()
    }

    /// Selecting a drive keeps whatever was typed for that same drive, so a
    /// single mistyped digit in a 48-digit recovery key does not cost all 48.
    ///
    /// Which drive that is, by what it is rather than by what it is called.
    /// Held as a device identifier, it named the slot and not the drive: eject
    /// one image and open another, the second lands on the identifier the
    /// first had, and the passphrase typed for the first was still sitting in
    /// the field. The engine then said what it says to a wrong passphrase, and
    /// the file looked as though it would not open.
    private var credentialBelongsTo: String?

    /// Bumped every time the drive being opened changes, including back to no
    /// drive at all. Anything started for a choice carries the value it was
    /// started under and does nothing once it has moved on.
    private var choiceGeneration = 0

    func choose(_ drive: Drive) {
        choiceGeneration += 1
        // Reload for a different drive, and whenever the field is empty. The
        // second condition matters because navigating away clears the value and
        // not this marker: without it the saved-key banner outlives the key it
        // describes, and Unlock then refuses for want of a credential the
        // interface reports holding.
        if credentialBelongsTo != identity(of: drive) || credential.isEmpty {
            // A stored credential is one that was asked to be remembered.
            if let saved = CredentialStore.load(for: identity(of: drive)) {
                credential = saved
                rememberCredential = true
                usingSavedCredential = true
            } else {
                credential = ""
                rememberCredential = false
                usingSavedCredential = false
            }
            credentialBelongsTo = identity(of: drive)
        }
        credentialProblem = nil
        notice = nil
        chosenFormat = nil

        // What the drive holds is settled before the screen is shown.
        //
        // Showing the passphrase field first and taking it away a moment later,
        // once nothing turned out to need unlocking, made an unencrypted drive
        // flash a demand for a password it does not have. The reading takes tens
        // of milliseconds, so the list stays up until it arrives.
        //
        // The engine has already looked inside a qcow2. No sector read here
        // sees past the container's mapping, so its answer stands.
        if let known = knownFormat, engineReadDrives[drive.id] != nil {
            knownFormat = nil
            chosenFormat = known == .unknown ? nil : known
            if known != .unknown { knownFormats[drive.id] = known }
            // The same screen whatever it holds. An encrypted one asks for the
            // passphrase; an unencrypted one asks only whether to open it
            // writable or read-only; and there is nothing to hand to macOS,
            // which cannot read a container of any of these kinds either.
            phase = .unlock(drive)
            return
        }

        // Coming from anywhere but the list -- Back on the failure screen is
        // the way here -- there is no list to hold up while the sector is
        // read, and both the reading below and its own fallback replace the
        // list and nothing else. Waiting there left the failure on screen and
        // Back doing nothing at all.
        if case .chooseDrive = phase {} else { phase = .unlock(drive) }

        guard canReadFirstSector(of: drive) else {
            phase = .unlock(drive)
            return
        }
        identify(drive)
    }

    /// What a report should carry as the engine's output.
    ///
    /// A failure on screen is what the reader is reporting, and the running
    /// status lines are cleared by then, so a report sent from there arrived
    /// describing the environment and nothing that happened.
    var reportableOutput: String {
        if case .failed(_, let summary, let detail) = phase {
            return ([summary] + [detail].compactMap { $0 }).joined(separator: "\n\n")
        }
        return statusLines.joined(separator: "\n")
    }

    /// The failure on screen, for a report's description to start from.
    var reportableSummary: String? {
        if case .failed(_, let summary, _) = phase { return summary }
        return nil
    }

    /// Whether the first sector of this drive can be read before deciding.
    ///
    /// A container file was attached by this user, so its device belongs to
    /// them. A physical drive is mode 640 root:operator and needs the helper.
    /// With neither available the drive is asked about as before.
    private func canReadFirstSector(of drive: Drive) -> Bool {
        openedImages[DriveScanner.wholeDisk(of: drive.id)] != nil || helper.isReady
    }

    /// What the chosen partition actually holds, once the helper has read it.
    ///
    /// Set only to a value worth stating. A drive whose first sector cannot be
    /// read, or is read as something unrecognised, leaves this nil and the
    /// screen unchanged.
    /// Whether this mount waits for macOS to authorise it, which only the
    /// route without the helper does. The step list is drawn from it.
    @Published var mountAsksApproval = false
    @Published var chosenFormat: VolumeFormat?
    /// What a probe made of each drive it has read, by drive identifier. The
    /// list says what a volume may be until this says what it is.
    @Published var knownFormats: [String: VolumeFormat] = [:]
    /// What an encrypted drive turned out to hold, once it was open. A lock
    /// says nothing about what is behind it until it is opened.
    @Published var knownFilesystems: [String: String] = [:]

    /// Which container the drive on screen is, where it is an image.
    ///
    /// Nil for a physical drive, and for an image opened before this was
    /// recorded. What the screen says about writing depends on it.
    var chosenContainer: ContainerFormat? {
        guard case .unlock(let drive) = phase else { return nil }
        return containerFormats[drive.id]
            ?? containerFormats[DriveScanner.wholeDisk(of: drive.id)]
    }

    /// Whether the image on screen can be written to at all.
    ///
    /// A VHDX cannot: writing one means writing to its log first, which the
    /// driver does not do. Everything else, including a physical drive, can.
    var chosenIsWritable: Bool { chosenContainer?.isWritable ?? true }

    /// Ask the helper what is on the drive, in the background.
    ///
    /// A Microsoft Basic Data partition is BitLocker, plain NTFS or exFAT and
    /// the partition type does not say which — so until this comes back the
    /// only way to find out has been to type a password and watch it fail.
    /// Linux partitions are left alone, LUKS announcing itself in its own header
    /// and the engine's probe already reporting it.
    private func identify(_ drive: Drive) {
        let devicePath = drive.devicePath
        let identifier = drive.id
        let ours = openedImages[DriveScanner.wholeDisk(of: drive.id)] != nil
        let choice = choiceGeneration

        // A slow reading, from a helper that has gone away or a drive that will
        // not answer, must still leave the click with an effect. Asking for the
        // passphrase is the fallback.
        //
        // Only for as long as that drive is still the one being opened. This
        // waits a second and a half, which is long enough to press Back, and
        // the screen it puts up then belongs to a drive nobody is looking at
        // any more: the list would sit there and turn into a passphrase prompt
        // on its own.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.chosenFormat == nil, self.choiceGeneration == choice
            else { return }
            if case .chooseDrive = self.phase { self.phase = .unlock(drive) }
        }

        Task { [weak self] in
            guard let self else { return }
            let format: VolumeFormat
            if ours {
                format = await Task.detached(priority: .userInitiated) {
                    BootSector.read(devicePath: devicePath).map(BootSector.identify) ?? .unknown
                }.value
            } else {
                format = await self.helper.identify(devicePath: devicePath)
            }
            // The screen may have moved on while the helper read a sector.
            // Answering about a drive nobody is looking at would put a sentence
            // about one drive under the name of another.
            let stillWanted: Bool
            if self.choiceGeneration != choice {
                // Somebody went back, or picked something else, while a sector
                // was being read. The answer is about a drive that is no longer
                // on screen, and acting on it would put one there.
                stillWanted = false
            } else if case .chooseDrive = self.phase {
                stillWanted = drive.id == identifier
            } else if case .unlock(let current) = self.phase {
                stillWanted = current.id == identifier
            } else {
                stillWanted = false
            }
            guard stillWanted else { return }

            Log.drives.notice("identified as \(format.rawValue, privacy: .public)")
            self.chosenFormat = format == .unknown ? nil : format
            // Kept for the list as well as for this screen. Going back from
            // here otherwise showed "BitLocker/NTFS" again for a drive the app
            // had just read the boot sector of.
            if format != .unknown { self.knownFormats[identifier] = format }

            // Nothing to unlock, so nothing to ask, and a screen that asks
            // anyway is in the way.
            //
            // Unconditional. Waiting for the field to be empty read as "unless
            // something has been typed", which it was not: the sector returns in
            // tens of milliseconds, before anyone could type, and the only thing
            // that filled the field by then was a passphrase from the Keychain,
            // which is of no use to a drive that needs none.
            if format.macOSHandlesFully {
                // macOS mounts this locally, read and write. Opening it here
                // would hand back a network volume instead.
                self.handToMacOS(drive)
            } else if format.isUnencrypted {
                // Nothing to unlock, and still a choice to make: read-write or
                // read-only. The screen asks that and nothing else, with no
                // passphrase field, since there is no passphrase.
                Log.mount.notice("nothing is encrypted, asking how to open it")
                self.phase = .unlock(drive)
            } else {
                // It needs a passphrase, so the screen that asks for one.
                self.phase = .unlock(drive)
            }
        }
    }

    /// What to say about a mount that fell back to read-only.
    ///
    /// The same rules that explain a failure explain this: the writable attempt
    /// did fail, and its complaint is in the transcript, ahead of the read-only
    /// attempt that succeeded. Only a rule counts. The engine's own last line
    /// is what `Diagnosis` falls back on for a failure, and beside a drive that
    /// did open it would read as though something had gone wrong.
    private nonisolated static func reasonForFallback(
        _ transcript: String, _ statusLines: [String]
    ) -> String? {
        let text = transcript.isEmpty ? statusLines.joined(separator: "\n") : transcript
        guard let rule = Diagnosis.rule(for: text) else { return nil }
        Log.mount.notice("read-only fallback explained by \(rule.name, privacy: .public)")
        return rule.message()
    }

    // MARK: Putting back what was open

    /// Whether a restore is running, so that nothing it does reaches the
    /// screen. The person did not ask for any of it to be shown: as far as they
    /// are concerned the drives are simply there, the way macOS mounts a disk.
    private var restoring = false

    /// Whether the permission screen is up because a restore could not run,
    /// rather than because the app has just been installed.
    ///
    /// The screen is the same; what it says at the top is not. Somebody who
    /// switched restoring on has granted the permission once already, and is
    /// owed the reason they are being asked again.
    @Published var restoreBlocked = false

    /// What is still to be put back, one at a time. The engine will not have
    /// two mounts started at once the first time it runs after an update, and
    /// serially is fast enough for the handful of drives anyone keeps open.
    private var restoreQueue: [MountMemory.Entry] = []

    /// Record that this drive is open, so that it can be opened again after a
    /// restart. Kept whether or not the setting is on, so that turning it on
    /// puts back what is open now rather than waiting for the next mount.
    private func rememberForRestore(_ drive: Drive, readOnly: Bool) {
        MountMemory.remember(
            MountMemory.Entry(
                uuid: drive.uuid,
                imagePath: openedImages[DriveScanner.wholeDisk(of: drive.id)]?.path
                    ?? engineReadDrives[drive.id].map { _ in drive.uuid },
                volumeIdentifier: nil,
                readOnly: readOnly,
                name: drive.name))
    }

    /// Open again whatever was open, if the setting is on.
    ///
    /// Called after every scan, so a drive plugged in an hour after login is
    /// put back as readily as one already attached at the time.
    func restoreRememberedMounts() {
        guard RestorePreference.isOn, !restoring, mountTask == nil else { return }
        let waiting = MountMemory.all().filter { !isAlreadyOpen($0) }
        guard !waiting.isEmpty else { return }

        // A drive that is not a container file is read at the raw device, which
        // needs Full Disk Access. Anyone who turned this setting on granted it
        // once; that it has gone since is worth saying, because the alternative
        // is drives that quietly do not come back.
        if !hasFullDiskAccess, waiting.contains(where: { $0.imagePath == nil }) {
            Log.mount.notice("drives cannot be put back: no full disk access")
            restoreBlocked = true
            phase = .needsPermission
            return
        }
        restoring = true
        restoreQueue = waiting
        Log.mount.notice("putting back \(waiting.count, privacy: .public) drives")
        restoreNext()
    }

    /// Whether this entry is already open, which is the usual case for
    /// everything but the first scan after a restart.
    private func isAlreadyOpen(_ entry: MountMemory.Entry) -> Bool {
        guard let drive = drives.first(where: { $0.uuid == entry.uuid }) else { return false }
        return openMounts[drive.devicePath] != nil
    }

    private func restoreNext() {
        guard RestorePreference.isOn, !restoreQueue.isEmpty else {
            restoring = false
            restoreQueue = []
            return
        }
        let entry = restoreQueue.removeFirst()
        Task { @MainActor in
            await self.restore(entry)
            // Whatever happened, the next one is tried: a drive that is not
            // plugged in must not hold up one that is.
            self.restoreNext()
        }
    }

    /// Put one drive or image back, silently.
    ///
    /// Anything that does not work is passed over: a drive that is not
    /// connected, an image that has been moved or deleted, a volume whose
    /// passphrase was never saved. There is nobody sitting there to answer a
    /// question, so nothing is asked.
    private func restore(_ entry: MountMemory.Entry) async {
        var drive = drives.first { $0.uuid == entry.uuid }
        if drive == nil, let path = entry.imagePath {
            drive = await openImageQuietly(URL(fileURLWithPath: path))
        }
        guard let drive else { return }
        guard openMounts[drive.devicePath] == nil else { return }

        // A drive that needs a passphrase comes back only if it was saved. The
        // rest open with nothing.
        let saved = CredentialStore.load(for: identity(of: drive))
        let credential = saved.flatMap { try? Credential.normalise($0).get() } ?? ""

        // With no saved passphrase, a locked volume is left locked rather than
        // tried with an empty one. The attempt takes a minute, starts a virtual
        // machine, and ends in a failure nobody asked for and nobody is there
        // to read.
        if saved == nil, await probedFormat(of: drive).isEncrypted {
            Log.mount.notice("a drive was left closed: it is locked and no passphrase was saved")
            return
        }

        let cannotBeWritten = containerFormats[drive.id].map { !$0.isWritable } ?? false
        mountingReadOnly = entry.readOnly || cannotBeWritten
        statusLines = []
        Log.mount.notice(
            "putting back a drive, read-only \(self.mountingReadOnly, privacy: .public)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            restoreFinished = { continuation.resume() }
            runMount(drive: drive, credential: credential)
        }
        restoreFinished = nil
    }

    /// Called once the mount in flight has ended, however it ended.
    private var restoreFinished: (() -> Void)?

    /// What is on a drive, read once and remembered.
    ///
    /// The same reading the unlock screen makes, asked for where there is
    /// nobody to answer a prompt. Unknown where nothing can read it, which is
    /// treated as unencrypted: a drive that opens with no passphrase is worth
    /// trying, and one that does not fails silently.
    private func probedFormat(of drive: Drive) async -> VolumeFormat {
        if let known = knownFormats[drive.id] { return known }
        let devicePath = drive.devicePath
        let format: VolumeFormat
        if openedImages[DriveScanner.wholeDisk(of: drive.id)] != nil {
            format = await Task.detached(priority: .utility) {
                BootSector.read(devicePath: devicePath).map(BootSector.identify) ?? .unknown
            }.value
        } else if helper.isReady {
            format = await helper.identify(devicePath: devicePath)
        } else {
            format = .unknown
        }
        if format != .unknown { knownFormats[drive.id] = format }
        return format
    }

    /// Attach an image and list what is in it, without any of it being shown.
    ///
    /// The ordinary route puts a sheet up and moves the screen to the drive it
    /// opened. Here the file is opened, the drive it produced is added to the
    /// list, and nothing else happens.
    private func openImageQuietly(_ url: URL) async -> Drive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let alreadyOpen = Set(openedImages.keys)
        let outcome = await Task.detached(priority: .utility) {
            Self.attachAndList(url, alreadyOpen: alreadyOpen)
        }.value
        switch outcome {
        case .failure:
            return nil
        case .qcow2(let drive, let format, let container):
            engineReadDrives[drive.id] = drive
            drives = inArrivalOrder(drives + [drive])
            knownFormat = format
            knownFormats[drive.id] = format
            containerFormats[drive.id] = container
            return drive
        case .success(let attached, let all, _):
            openedImages[attached.identifier] = url
            containerFormats[attached.identifier] = .raw
            drives = inArrivalOrder(reconcileImages(all, attachments: nil))
            return drives.first { $0.uuid == url.path }
        }
    }

    func backToDrives() {
        choiceGeneration += 1
        credential = ""
        credentialProblem = nil
        chosenFormat = nil
        phase = .chooseDrive
    }

    var credentialHint: String? { Credential.hint(for: credential) }

    /// Where a drive is open, if it is, so that the drive list can report its
    /// state without navigating away.
    @Published var openMounts: [String: String] = [:]

    func mountPoint(for drive: Drive) -> String? {
        if let direct = openMounts[drive.devicePath] { return direct }
        // A volume inside a container is reported against its logical name,
        // "lvm:<vg>:<disk>:<lv>", rather than against the device. Looking the
        // drive up by device path therefore finds nothing and the row reports it
        // closed while Finder shows it open. That identifier carries the disk,
        // which ties the mount back to the drive.
        return openMounts.first { drive.owns($0.key) }?.value
    }

    // MARK: Choosing a drive, and unlocking it

    /// Whether this drive has already been read and found not to be encrypted.
    ///
    /// The one case where an empty field is an answer rather than an omission.
    var chosenDriveIsOpenAlready: Bool {
        chosenFormat?.isUnencrypted ?? false
    }

    /// Whether the mount being asked for is read-only.
    ///
    /// Carried from the button that started it through to the script, and read
    /// back afterwards so the mounted screen can say which it was.
    @Published var mountingReadOnly = false

    /// Whether the drive on screen ended up read-only, whether or not that was
    /// what was asked for. A drive that refused to be written to is mounted
    /// read-only rather than not at all, and says so.
    @Published var mountedReadOnly = false

    /// Why the drive on screen ended up read-only, where it was not asked for.
    ///
    /// A drive that refuses to be written to is mounted read-only rather than
    /// left closed, and the reason is in what the engine said while the
    /// writable attempt failed. Without this the person is shown a drive that
    /// quietly will not accept writes and nothing about why: for the commonest
    /// cause, a Windows volume left hibernated or by Fast Startup, the remedy
    /// is one setting away and used to be stated when the mount failed
    /// outright.
    @Published var readOnlyReason: String?

    /// The mount points opened read-only, so the list can mark them.
    ///
    /// By mount point rather than by drive, because that is what the row has
    /// and what survives a rebuild of the list.
    @Published var readOnlyMounts: Set<String> = []

    func unlock(_ drive: Drive, readOnly: Bool = false) {
        credentialProblem = nil
        // A format that cannot be written is opened read-only whatever was
        // asked for. Mounting it writable appears to work and then refuses
        // every write, which is worse than saying so at the start.
        let readOnly = readOnly || !chosenIsWritable
        mountingReadOnly = readOnly
        let raw = credential
        // Nothing to unlock: the first sector reports it as unencrypted, so the
        // engine mounts it without a credential and whatever is in the field,
        // usually a remembered passphrase, does not apply.
        if chosenDriveIsOpenAlready {
            Log.mount.notice("opening an unencrypted drive, no credential needed")
            statusLines = []
            phase = .working(drive)
            runMount(drive: drive, credential: "")
            return
        }
        guard !raw.isEmpty else {
            // No saved key is held, whatever the interface reported. State that
            // before asking for one.
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

    // MARK: The three ways a drive opens

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
        if let previous = workspace { pastWorkspaces.append(previous) }
        workspace = ws

        // A container file needs no privilege at all: this user attached it, so
        // the device node is theirs and the NFS mount the engine makes is a
        // user mount. Neither the helper nor an authorisation prompt is
        // involved. The drive mounts under ~/Volumes rather than /Volumes,
        // which is the one visible difference.
        if openedImages[DriveScanner.wholeDisk(of: drive.id)] != nil
            || engineReadDrives[drive.id] != nil
        {
            Log.mount.notice("opening a container file without any privilege")
            mountAsksApproval = false
            runMountAsThisUser(drive: drive, credential: credential, workspace: ws)
            return
        }

        // With the helper approved, this needs no password at all. Without it,
        // fall back to asking macOS to authorise a single command.
        mountAsksApproval = !helper.isReady
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

            let readOnly = mountingReadOnly
            mountTask = Task {
                let outcome = await helper.mount(
                    drive: drive, aliasPath: aliasPath, volume: nil, credential: credential,
                    readOnly: readOnly)
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
                    self.finishMount(
                        drive: drive, credential: credential, mountPoint: point, route: .helper)
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
        let identifier = drive.id
        Task.detached(priority: .userInitiated) {
            let reported = EngineStatus.current()
            let nested = EngineStatus.nestedVolumes(under: fallback)
            let mine =
                nested.isEmpty
                ? reported
                    .filter { drive.owns($0.devicePath) }
                    .map(\.mountPoint)
                : nested
            // What was behind the lock. Known only now, an encrypted drive
            // saying nothing about its contents until it is open.
            let driver =
                reported.first { drive.owns($0.devicePath) || $0.mountPoint == fallback }?
                .driver ?? ""
            await MainActor.run {
                if !mine.isEmpty { self.openVolumes = mine }
                if !driver.isEmpty {
                    self.knownFilesystems[identifier] =
                        VolumeFormat.filesystemName(fromDriver: driver)
                }
            }
        }
    }

    /// Note when a container held more volumes than could be opened.
    private func noteVolumeCount(_ transcript: String) {
        guard let totalCount = MountScript.volumeShortfall(in: transcript) else { return }
        // One number rather than two. A sentence carrying two counts needs both
        // to agree with the noun, and languages do not agree alike.
        notice = appString(
            "This drive holds \(totalCount) volumes and not all of them could be opened.")
    }

    /// Record a successful mount, wherever it came from.
    /// Which of the three ways in was taken.
    ///
    /// Only the bookkeeping below differs by route, and only in two places: what
    /// the log says, and whether this is the moment to offer the helper for
    /// registration.
    enum MountRoute {
        /// The resident helper did it; no password was asked for.
        case helper
        /// The user authorised this one mount at the panel.
        case authorised
        /// A container file, opened with no privilege at all.
        case unprivileged
    }

    private func finishMount(
        drive: Drive, credential: String, mountPoint: String, transcript: String = "",
        route: MountRoute
    ) {
        // Read-only either because it was asked for, or because the drive
        // refused to be written to and the script fell back. The second is the
        // one worth reporting, and both are recorded the same way.
        let fellBack =
            transcript.contains(MountScript.stageMarker + "read-only")
            || statusLines.contains { $0.contains(MountScript.stageMarker + "read-only") }
        mountedReadOnly = mountingReadOnly || fellBack
        readOnlyReason = fellBack ? Self.reasonForFallback(transcript, statusLines) : nil
        if !transcript.isEmpty { noteVolumeCount(transcript) }
        if rememberCredential {
            if !CredentialStore.save(credential, for: identity(of: drive)) {
                ejectProblem = "The drive opened, but the key could not be saved to your Keychain."
            }
        } else {
            CredentialStore.delete(for: identity(of: drive))
        }
        if mountedReadOnly {
            readOnlyMounts.insert(mountPoint)
        } else {
            readOnlyMounts.remove(mountPoint)
        }
        DriveMemory.remember(mountPoint: mountPoint, for: drive.uuid)
        rememberForRestore(drive, readOnly: mountedReadOnly)
        switch route {
        case .authorised:
            // Authorisation has just been demonstrated, so this is the moment to
            // offer the helper and spare the next unlock the panel. macOS still
            // wants approval in Login Items, for which the panel then prompts.
            // Only here: the helper route already has one, and a container file
            // authorises nothing.
            if case .notInstalled = helper.state { helper.install() }
            Log.mount.notice("mounted with authorisation")
        case .helper:
            Log.mount.notice("mounted through the helper")
        case .unprivileged:
            Log.mount.notice("mounted without the helper")
        }
        openMounts[drive.devicePath] = mountPoint
        collectVolumes(for: drive, fallback: mountPoint)
        self.credential = ""
        credentialBelongsTo = nil
        if restoring {
            restoreFinished?()
        } else {
            phase = .mounted(drive, mountPoint)
        }
    }

    /// Run the engine as the user who is sitting there.
    ///
    /// Identical to the authorised route apart from the authorisation: the same
    /// script, progress and failures. Only container files reach it.
    private func runMountAsThisUser(drive: Drive, credential: String, workspace ws: Workspace) {
        let readOnly = mountingReadOnly
        mountTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try Mounter.mount(
                    drive: drive, credential: credential, workspace: ws, elevated: false,
                    readOnly: readOnly,
                    progress: { line in
                        Task { @MainActor in self.appendStatus(line) }
                    })
                await MainActor.run {
                    self.finishMount(
                        drive: drive, credential: credential, mountPoint: result.mountPoint,
                        transcript: result.transcript, route: .unprivileged)
                }
            } catch let err as EngineError {
                await MainActor.run {
                    self.fail(
                        drive, err.errorDescription ?? "The drive could not be opened.",
                        err.detail)
                }
            } catch {
                await MainActor.run {
                    self.fail(drive, "The drive could not be opened.", "\(error)")
                }
            }
        }
    }

    private func runMountWithAuthorisation(
        drive: Drive, credential: String, workspace ws: Workspace
    ) {
        let readOnly = mountingReadOnly
        // Held as the helper's is, so that Cancel reaches this route as well.
        mountTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try Mounter.mount(
                    drive: drive,
                    credential: credential,
                    workspace: ws,
                    readOnly: readOnly,
                    progress: { line in
                        Task { @MainActor in self.appendStatus(line) }
                    })
                await MainActor.run {
                    self.finishMount(
                        drive: drive, credential: credential, mountPoint: result.mountPoint,
                        transcript: result.transcript, route: .authorised)
                }
            } catch let err as EngineError {
                await MainActor.run {
                    if Permissions.isAccessDenied(err.detail ?? "") {
                        self.reportRefusal(drive, err)
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

    /// macOS refused the read. Say which permission it refused.
    ///
    /// The engine cannot tell them apart: Full Disk Access and the
    /// removable-volumes permission both come back as a refusal to read the
    /// device, in the same words. What can tell them apart is the record macOS
    /// keeps of what was granted, so it is read again here rather than trusted
    /// from start-up -- a permission can be withdrawn while the app is running,
    /// and this is the moment that proves it.
    ///
    /// Full Disk Access is asked for by a screen of its own. The
    /// removable-volumes permission is not: macOS prompts for it once and never
    /// again, so there is nothing to relaunch into, and the panel on the unlock
    /// screen already holds the row and the button that opens the right pane.
    /// Sending that reader to the Full Disk Access screen named a permission
    /// they had already given and left the one they had not out of it.
    private func reportRefusal(_ drive: Drive, _ err: EngineError) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let reading = Permissions.reading()
            await MainActor.run {
                guard let self else { return }
                self.applyPermissions(reading)
                if !reading.fullDiskAccess {
                    self.phase = .needsPermission
                } else if self.removableAccess == false {
                    Log.mount.notice("refused: removable volumes")
                    self.phase = .unlock(drive)
                    self.notice = appString(
                        "macOS refused \(appName) access to this drive. Switch on Removable Volumes below, then open it again."
                    )
                } else {
                    // Refused, and nothing recorded says by which permission.
                    // The failure screen carries the engine's own words, which
                    // is more than a screen naming the wrong setting would.
                    self.fail(
                        drive, err.errorDescription ?? "The drive could not be opened.",
                        err.detail)
                }
            }
        }
    }

    /// Every route to a failed mount goes through here, so the step the mount
    /// stopped on is recorded in one place instead of at each of the four
    /// sites that can fail.
    private func fail(_ drive: Drive?, _ summary: String, _ detail: String?) {
        // A failure is when somebody reaches for the report, so the log is
        // fetched again here rather than when the sheet is opened.
        refreshRecentLog()
        // Whatever the first sector reported, the drive did not open. The
        // reading is discarded so that a second attempt asks for a passphrase.
        // A volume wrongly read as unencrypted would otherwise be retried
        // without one indefinitely, with no way to type the password that would
        // have worked.
        chosenFormat = nil
        failedStage = MountStage.inferred(from: stageLines + statusLines)
        // The stage is generated here and safe to read back. The summary can
        // carry engine output, so it passes through the same redaction as the
        // report.
        Log.mount.error(
            "mount failed at \(String(describing: self.failedStage), privacy: .public): \(Diagnostics.redact(summary, secret: self.activeCredential))"
        )
        let clean =
            detail
            .map { Diagnostics.redact($0, secret: activeCredential) }
            .map(Diagnostics.withoutMarkers)
        // A restore that did not work says nothing: there is nobody sitting
        // there, and a failure screen for a drive nobody asked about would be
        // the first thing they saw at login.
        guard !restoring else {
            Log.mount.notice("a drive could not be put back; leaving it closed")
            restoreFinished?()
            return
        }
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
        // Redacted as it arrives, since the log is shown in the interface,
        // offered in bug reports and written to the workspace. There is then no
        // interval in which a credential exists in any of them.
        statusLines.append(Diagnostics.redact(line, secret: activeCredential))
        // Stage markers drive the indicator and are not output to be read.
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
        //
        // Asked of this drive and no other. `openVolumes` describes whichever
        // drive was opened last, so ejecting a drive while an image happened
        // to be the most recent thing opened took that image's mount down as
        // well and put the file back under somebody who had asked for neither.
        let owner = drives.first { mountPoint(for: $0) == path }
        let mine = openMounts.filter { mount in
            mount.value == path || mount.value.hasPrefix(path + "/")
                || (owner.map { $0.owns(mount.key) } ?? false)
        }
        var paths = Array(Set(mine.values))
        if !paths.contains(path) { paths.append(path) }
        // A volume nested inside this one is served through it and is nowhere
        // else: only the system's own mount table sees those.
        paths += openVolumes.filter { $0.hasPrefix(path + "/") && !paths.contains($0) }
        let roots = paths.filter { point in
            !paths.contains { $0 != point && point.hasPrefix($0 + "/") }
        }
        // Which devices these mounts belong to, read before they are cleared:
        // afterwards there is nothing left to say which container file was
        // being served.
        let devices = Array(mine.keys) + (owner.map { [$0.devicePath] } ?? [])
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
                    self.openVolumes = self.openVolumes.filter { !paths.contains($0) }
                    // Ejecting is the person saying they are done with it, so
                    // it is not put back at the next login. Unplugging is not:
                    // a drive that goes away without being ejected is one to
                    // open again when it comes back.
                    for uuid in devices.compactMap({ device in
                        self.drives.first { $0.devicePath == device }?.uuid
                    }) {
                        MountMemory.forget(uuid: uuid)
                    }
                    if self.openMounts.isEmpty { self.onAllDrivesClosed?() }
                    self.openMounts = self.openMounts.filter { !paths.contains($0.value) }
                    // The list, not start(): with a single drive attached that
                    // selects it again and reopens the unlock screen, which is
                    // the opposite of what ejecting asked for.
                    self.credential = ""
                    self.credentialBelongsTo = nil
                    self.credentialProblem = nil
                    self.statusLines = []
                    // Before the list is rebuilt, so the rebuilt one does not
                    // put back a row for a file that is going away.
                    self.detachImages(forDevices: devices)
                    self.forgetEngineRead(devices)
                    self.showAllDrives()
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
        // What was attached is put back. A container file opened during a
        // session used to stay attached after the app had gone, and turned up
        // in the list next time as a disk with no name and no explanation --
        // attaching being this app's business and nobody else's.
        let leaving = ImageList.detachingOnQuit(
            opened: openedImages, mountedDevices: Array(openMounts.keys))
        if !leaving.isEmpty {
            Log.drives.notice("detaching \(leaving.count, privacy: .public) container files")
            for identifier in leaving { DiskImage.detach("/dev/" + identifier) }
        }
        workspace?.destroy()
        workspace = nil
        for past in pastWorkspaces { past.destroy() }
        pastWorkspaces = []
        EngineConfig.removeGeneratedAction()
    }
}
