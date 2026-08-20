import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().opacity(0.5)
            Group {
                switch model.phase {
                case .needsPermission:     PermissionView()
                case .scanning:            ScanningView()
                case .chooseDrive:         DriveListView()
                case .unlock(let d):       UnlockView(drive: d)
                case .working(let d):      WorkingView(drive: d)
                case .chooseVolume(let d, let vols):
                    VolumeChoiceView(drive: d, volumes: vols)
                case .mounted(let d, let p): MountedView(drive: d, mountPoint: p)
                case .failed(let d, let s, let detail):
                    FailureView(drive: d, summary: s, detail: detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 420, idealHeight: 450)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showHelp) { HelpSheet() }
    }
}

// MARK: - Chrome

private struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lukotta").font(.headline)
                Text("Open encrypted drives on macOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("How Lukotta works, and what it supports")
            .accessibilityLabel("About Lukotta")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct ScanningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Looking for encrypted drives…").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permission

private struct PermissionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Lukotta").font(.title3.weight(.semibold))
                    Text("Lukotta opens BitLocker and Linux drives that macOS cannot read on its own. One setting is needed first.\n\nReading a drive at the raw device level needs Full Disk Access — an administrator password is not enough, and the removable-volumes permission covers files on a drive, not the raw device. macOS has no way for an app to request this one, so it has to be switched on by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Step(number: 1, text: "Open Privacy & Security → Full Disk Access.")
                Step(number: 2, text: "Click + and add Lukotta, then switch it on.")
                Step(number: 3, text: "Come back here and choose Relaunch — a new permission only applies to a freshly started app.")
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            InfoBox(icon: "hand.raised",
                    text: "This is a macOS privacy setting, not a change to your Mac. You can switch it off again at any time, and nothing is installed.")

            Spacer()
            HStack {
                Button("Reveal App") { model.revealApp() }
                Spacer()
                Button("Relaunch") { model.relaunch() }
                Button("Check Again") { model.recheckPermission() }
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.tint))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Drive selection

private struct DriveListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.drives.isEmpty {
            EmptyStateView(
                icon: "externaldrive.badge.questionmark",
                title: "No encrypted drives found",
                message: "Connect the encrypted drive and choose Rescan. If it is already connected, macOS may have it mounted — eject it in Finder first.",
                actionTitle: "Rescan",
                action: model.rescan)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Select a drive to unlock")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.drives) { drive in
                            DriveRow(drive: drive,
                                     mountPoint: model.mountPoint(for: drive),
                                     action: { model.choose(drive) },
                                     eject: { model.eject(model.mountPoint(for: drive) ?? "") })
                        }
                    }
                }
                HStack {
                    Text("Encrypted and Windows volumes are listed. A partition's contents can only be confirmed once it is unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Rescan", action: model.rescan)
                }
            }
        }
    }
}

private struct DriveRow: View {
    let drive: Drive
    let mountPoint: String?
    let action: () -> Void
    let eject: () -> Void

    private var isMounted: Bool { mountPoint != nil }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark"
                                        : "externaldrive.fill.badge.lock")
                .font(.system(size: 26))
                .foregroundStyle(isMounted ? Color.green : Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(drive.name).font(.body.weight(.medium))
                    TypePill(text: drive.kind.summary, open: isMounted)
                }
                // Size leads; the device identifier is the least useful fact
                // and no longer competes with it.
                Text(isMounted
                     ? "Open at \(mountPoint ?? "")"
                     : "\(drive.sizeDescription)  ·  \(drive.connection)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isMounted {
                Button("Eject", action: eject).controlSize(.small)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { if !isMounted { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(drive.name), \(drive.sizeDescription), \(drive.kind.summary)")
        .accessibilityHint(isMounted ? "Already open" : "Unlock this drive")
        .accessibilityAddTraits(.isButton)
    }
}

/// Small label for what a partition might contain.
private struct TypePill: View {
    let text: String
    let open: Bool

    var body: some View {
        Text(open ? "Open" : text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((open ? Color.green : Color.secondary).opacity(0.15)))
            .foregroundStyle(open ? Color.green : Color.secondary)
    }
}

// MARK: - Unlock

private struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @FocusState private var focused: Bool
    @State private var capsLockOn = false
    @State private var capsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Unlock “\(drive.name)”").font(.title3.weight(.semibold))
                Text("\(drive.sizeDescription) · \(drive.devicePath)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Password or recovery key").font(.subheadline)
                HStack(spacing: 8) {
                    Group {
                        if model.revealCredential {
                            TextField("", text: $model.credential)
                        } else {
                            SecureField("", text: $model.credential)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { model.unlock(drive) }

                    Button {
                        model.revealCredential.toggle()
                    } label: {
                        Image(systemName: model.revealCredential ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(model.revealCredential ? "Hide" : "Show")
                    .accessibilityLabel(model.revealCredential
                                        ? "Hide the credential" : "Show the credential")
                }

                if capsLockOn {
                    Label("Caps Lock is on", systemImage: "capslock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let hint = model.credentialHint {
                    Label(hint, systemImage: "number")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = model.credentialProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Remember this key in my Keychain", isOn: $model.rememberCredential)
                    .font(.callout)
                    .padding(.top, 2)

                Text("The password the drive was locked with, or a 48-digit BitLocker recovery key. Spaces and hyphens in a recovery key are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionsPanel()

            Spacer()
            HStack {
                Button("Back", action: model.backToDrives)
                Spacer()
                Button("Unlock") { model.unlock(drive) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.credential.isEmpty)
            }
        }
        .onAppear {
            focused = true
            capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
            capsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                capsLockOn = event.modifierFlags.contains(.capsLock)
                return event
            }
        }
        .onDisappear {
            if let capsMonitor { NSEvent.removeMonitor(capsMonitor) }
            capsMonitor = nil
        }
    }
}

/// What macOS asks for, why, and what still needs doing.
///
/// Shown open whenever something is outstanding — this is what a user needs
/// before they hit a wall, not something to go looking for. Once everything is
/// granted it collapses to a single line.
private struct PermissionsPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Bool

    private let fullDiskGranted: Bool

    init() {
        let granted = Permissions.hasFullDiskAccess
        self.fullDiskGranted = granted
        _expanded = State(initialValue: !granted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: fullDiskGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(fullDiskGranted ? Color.green : Color.orange)
                    Text(fullDiskGranted
                         ? "Permissions granted"
                         : "One permission still needs your approval")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionRow(
                        icon: "externaldrive.fill",
                        title: "Access to removable volumes",
                        detail: "Lukotta reads the drive directly in order to unlock it. Only the drive you choose is read.",
                        status: .automatic("Asked by macOS"),
                        action: ("Settings", { model.openFilesAndFoldersSettings() }))

                    PermissionRow(
                        icon: "key.fill",
                        title: "Your administrator password",
                        detail: "Reading a raw disk and mounting a volume both need it. macOS asks once per unlock, and Lukotta never sees it.",
                        status: .automatic("Asked each unlock"),
                        action: nil)

                    PermissionRow(
                        icon: "lock.shield.fill",
                        title: "Full Disk Access",
                        detail: fullDiskGranted
                            ? "Granted. This is what lets Lukotta read the drive at all."
                            : "macOS blocks raw disk reads without it, even for administrators. It is the one permission an app cannot request — it has to be switched on by hand.",
                        status: fullDiskGranted ? .granted : .needed,
                        action: fullDiskGranted ? nil
                                                : ("Open Settings", { model.openPrivacySettings() }))
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

private enum PermissionStatus {
    case granted
    case needed
    case automatic(String)
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: PermissionStatus
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title).font(.subheadline.weight(.semibold))
                    badge
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var tint: Color {
        switch status {
        case .granted:   return .green
        case .needed:    return .orange
        case .automatic: return .accentColor
        }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .needed:
            Text("Needed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        case .automatic(let note):
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Working

private struct WorkingView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @State private var showDetail = false

    private var stage: MountStage { MountStage.inferred(from: model.statusLines) }

    /// The unpack reports a percentage; surface it rather than the stage list.
    private var unpackProgress: String? {
        model.statusLines.last(where: { $0.contains("Setting up the Linux environment") })
            .flatMap { $0.contains("%") ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Opening “\(drive.name)”").font(.title3.weight(.semibold))
                Text("This usually takes under a minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let unpackProgress {
                VStack(alignment: .leading, spacing: 7) {
                    Text(unpackProgress).font(.callout)
                    ProgressView(value: percent(of: unpackProgress), total: 100)
                        .progressViewStyle(.linear)
                    Text("The Linux environment is unpacked once, on first use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(MountStage.allCases, id: \.rawValue) { s in
                        StageRow(stage: s, current: stage)
                    }
                }
            }

            DisclosureGroup("Details", isExpanded: $showDetail) {
                LogView(lines: model.statusLines)
            }
            .font(.caption)
            Spacer()
        }
    }

    private func percent(of text: String) -> Double {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        return Double(digits.last.map(String.init) ?? "0") ?? 0
    }
}

private struct StageRow: View {
    let stage: MountStage
    let current: MountStage

    private var done: Bool { stage.rawValue < current.rawValue }
    private var active: Bool { stage == current }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)

            Text(stage.title)
                .font(.callout)
                .foregroundStyle(active ? .primary : (done ? .secondary : .tertiary))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title): \(done ? "done" : active ? "in progress" : "waiting")")
    }
}

// MARK: - Choosing a volume

/// Shown when an unlocked container holds several logical volumes — the normal
/// case for Ubuntu, Debian and Fedora, which put root, home and swap inside one
/// LUKS container.
private struct VolumeChoiceView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    let volumes: [LogicalVolume]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a volume").font(.title3.weight(.semibold))
                Text("“\(drive.name)” is unlocked and contains \(volumes.count) volumes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(volumes, id: \.identifier) { vol in
                        Button { model.choose(vol, on: drive) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 22)).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vol.label).font(.body.weight(.medium))
                                    Text("\(vol.filesystem) · \(vol.size)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InfoBox(icon: "lock.open",
                    text: "The drive stays unlocked, so opening one of these will not ask for the password again.")

            Spacer()
            HStack {
                Button("Back", action: model.backToDrives)
                Spacer()
            }
        }
    }
}

// MARK: - Mounted

private struct MountedView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    let mountPoint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(drive.name)” is unlocked").font(.title3.weight(.semibold))
                    Text("Available in Finder, and readable and writable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledContent("Location") {
                Text(mountPoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }

            InfoBox(icon: "sidebar.left",
                    text: "The drive appears in the Finder sidebar under Locations. Eject it here or in Finder before unplugging it.")

            if let problem = model.ejectProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button("Show in Finder") { model.revealInFinder(mountPoint) }
                Spacer()
                if model.isEjecting {
                    ProgressView().controlSize(.small)
                    Text("Ejecting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Eject") { model.eject(mountPoint) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(model.isEjecting)
        }
    }
}

// MARK: - Failure

private struct FailureView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive?
    let summary: String
    let detail: String?
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The drive was not opened").font(.title3.weight(.semibold))
                    Text(summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InfoBox(icon: "shield.checkered",
                    text: "Your drive was not modified. A failed unlock cannot damage the data on it.")

            if let detail, !detail.isEmpty {
                DisclosureGroup("What the engine reported", isExpanded: $showDetail) {
                    LogView(lines: detail.components(separatedBy: .newlines).filter { !$0.isEmpty })
                }
                .font(.caption)
            }

            Spacer()
            HStack {
                Button("Choose another drive", action: model.backToDrives)
                Spacer()
                if summary.contains("Full Disk Access") {
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                        .keyboardShortcut(.defaultAction)
                } else if let drive {
                    Button("Try again") { model.choose(drive) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct InfoBox: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .onChange(of: lines.count) { _, n in
                withAnimation { proxy.scrollTo(max(0, n - 1), anchor: .bottom) }
            }
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button(actionTitle, action: action).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Help

/// How the app works, what it supports, and what it cannot do.
///
/// Also the only route to the licence and third-party notices, which ship in
/// the bundle — for a GPL application those need to be reachable, not just
/// present.
struct HelpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("About Lukotta").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HelpSection(title: "How it works") {
                        Text("Lukotta starts a small Linux virtual machine, unlocks the drive inside it, and shares the result back to Finder over a local connection. macOS has no built-in support for BitLocker or Linux filesystems, so the work happens in Linux, where it is well supported.")
                        Text("Nothing is installed on your Mac. The engine ships inside the app, no drive is written to unless you write to it, and nothing leaves your machine.")
                    }

                    HelpSection(title: "What it can open") {
                        Bullet("BitLocker drives, unlocked with the volume password or a 48-digit recovery key")
                        Bullet("Windows NTFS drives, including ones Windows left in a hibernated or unclean state")
                        Bullet("LUKS drives from Linux, both LUKS1 and LUKS2")
                        Bullet("LVM inside LUKS, the layout Ubuntu, Debian, Mint and Fedora use — if the container holds several volumes, Lukotta asks which to open")
                        Bullet("ext4, btrfs and XFS filesystems inside those containers")
                    }

                    HelpSection(title: "What it cannot open") {
                        Bullet("Drives sealed to a TPM rather than a password, including Ubuntu's newer hardware-backed encryption")
                        Bullet("LUKS volumes whose header is stored separately from the drive")
                    }

                    HelpSection(title: "Why it appears as a network drive") {
                        Text("The unlocked volume is shared back to Finder over a local network connection, so macOS files it under Locations and shows it with a network icon. It reads and writes normally, and ejecting works as usual. macOS provides no way to present it as a local disk.")
                    }

                    HelpSection(title: "Permissions") {
                        Bullet("Full Disk Access — macOS blocks reading a drive at the raw level without it. It is the one permission an app cannot request, so it must be switched on by hand")
                        Bullet("Removable volumes — requested by macOS the first time a drive is read")
                        Bullet("Administrator password — required once per unlock to read the disk and mount the volume. Lukotta never sees it")
                    }

                    HelpSection(title: "Licence") {
                        Text("Lukotta is free software under the GPL, version 3 or later. It is built on anylinuxfs, which does the hard part. Complete source for every component is published alongside each release.")
                        HStack(spacing: 10) {
                            Button("Licence") { model.openBundledDocument("LICENSE") }
                            Button("Third-Party Notices") { model.openBundledDocument("THIRD_PARTY_NOTICES.md") }
                            Button("Project Page") { model.openProjectPage() }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }

                    HelpSection(title: "Requirements") {
                        Bullet("An Apple Silicon Mac. Intel Macs are not supported")
                        Bullet("macOS 15 Sequoia or later")
                    }

                    Text(version).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(22)
            }
        }
        .frame(width: 580, height: 560)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .kerning(0.6)
            VStack(alignment: .leading, spacing: 7) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                .offset(y: -2)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
