import AppKit
import LukottaCore
import SwiftUI

// MARK: - Unlock

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @FocusState private var focused: Bool
    @State private var capsLockOn = false
    @State private var capsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unlock “\(drive.name)”").font(.title3.weight(.semibold))
                        Text("\(drive.sizeDescription) · \(drive.devicePath)")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if model.usingSavedCredential {
                        // A stored key and a field of dots asking to store it again is
                        // two states at once. Show the one that applies.
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Using the key saved in your Keychain")
                                    .font(.callout.weight(.medium))
                                Text("Unlock uses it directly. Forget it to type a different one.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { model.forgetSavedCredential(for: drive) }
                                .controlSize(.small)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.25)))

                        if let problem = model.credentialProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(drive.kind == .linux ? "Passphrase" : "Password or recovery key")
                                .font(.subheadline)
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
                                .accessibilityLabel(
                                    drive.kind == .linux
                                        ? "Passphrase" : "Password or recovery key")

                                Button {
                                    model.revealCredential.toggle()
                                } label: {
                                    Image(systemName: model.revealCredential ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .help(model.revealCredential ? "Hide" : "Show")
                                .accessibilityLabel(
                                    model.revealCredential
                                        ? "Hide the credential" : "Show the credential")
                            }

                            if capsLockOn {
                                Label("Caps Lock is on", systemImage: "capslock.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .onAppear {
                                        AccessibilityNotification.Announcement(
                                            "Caps Lock is on"
                                        ).post()
                                    }
                            }
                            // The 48-digit hint counts BitLocker recovery-key
                            // digits, which mean nothing on a LUKS drive.
                            if drive.kind != .linux, let hint = model.credentialHint {
                                Label(hint, systemImage: "number")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let problem = model.credentialProblem {
                                Label(problem, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Toggle(
                                "Remember this key in my Keychain", isOn: $model.rememberCredential
                            )
                            .font(.callout)
                            .padding(.top, 2)

                            // A recovery key is a BitLocker idea. Offering one
                            // to a LUKS drive describes something that does not
                            // exist for it.
                            Text(
                                drive.kind == .linux
                                    ? "The passphrase this drive was encrypted with."
                                    : "The password the drive was locked with, or a 48-digit BitLocker recovery key. Spaces and hyphens in a recovery key are ignored."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    PermissionsPanel()

                }
                .padding(.bottom, 4)
            }
            Spacer(minLength: 12)
            HStack {
                Button("Back", action: model.backToDrives)
                Spacer()
                Button("Unlock") { model.unlock(drive) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.credential.isEmpty && !model.usingSavedCredential)
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
struct PermissionsPanel: View {
    @EnvironmentObject var model: AppModel

    private var removableDetail: String {
        if model.removableAccess == false {
            // A bare button into a settings pane is a dead end. Say what to do
            // once it opens.
            return
                "Was refused. In Files and Folders, switch on Removable Volumes for \(Brand.name), then come back."
        }
        return "Lets \(Brand.name) see the drives you plug in."
    }

    private var removableStatus: PermissionStatus {
        switch model.removableAccess {
        case true: return .granted
        case false: return .needed
        default: return .automatic("Asked when needed")
        }
    }

    /// Only rows that are actually granted show "Granted"; the rest show a
    /// button or a neutral note, never both.

    private var helperDetail: String {
        switch model.helper.state {
        case .ready:
            return
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do."
        case .awaitingApproval:
            return
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do. Approve \(Brand.name) in Login Items to finish."
        default:
            return
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do. \(Brand.name) never sees your password."
        }
    }

    private var helperStatus: PermissionStatus {
        switch model.helper.state {
        case .ready: return .granted
        case .awaitingApproval: return .needed
        default: return .automatic("Asked each time")
        }
    }

    private var helperAction: (String, () -> Void)? {
        switch model.helper.state {
        case .ready: return nil
        case .awaitingApproval: return ("Approve", { model.helper.openLoginItemsSettings() })
        default: return ("Set Up", { model.helper.install() })
        }
    }
    @State private var expanded: Bool

    init() {
        _expanded = State(initialValue: true)
    }

    private var fullDiskGranted: Bool { model.hasFullDiskAccess }
    private var settled: Bool { model.allPermissionsSettled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: settled ? "checkmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(settled ? Color.green : Color.orange)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    Text(
                        settled
                            ? "All required permissions granted"
                            : "Some permissions are still needed"
                    )
                    .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Which way the chevron points is the only sign of whether this is
            // open, and a chevron is not something a screen reader can see.
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hide the details" : "Show what each permission is for")

            // Open while anything is outstanding; the user can still collapse it.
            if expanded || !settled {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionRow(
                        number: 1,
                        title: "Seeing connected drives",
                        detail: removableDetail,
                        status: removableStatus,
                        action: model.removableAccess == false
                            ? ("Settings", { model.openFilesAndFoldersSettings() }) : nil)

                    PermissionRow(
                        number: 2,
                        title: "Administrator password",
                        detail: helperDetail,
                        status: helperStatus,
                        action: helperAction)

                    PermissionRow(
                        number: 3,
                        title: "Full Disk Access",
                        detail: fullDiskGranted
                            ? "Lets \(Brand.name) read the encrypted data itself."
                            : "Lets \(Brand.name) read the encrypted data itself. macOS blocks this without it, even for administrators, and it cannot be requested — it has to be switched on by hand.",
                        status: fullDiskGranted ? .granted : .needed,
                        action: fullDiskGranted
                            ? nil
                            : ("Open Settings", { model.openPrivacySettings() }))
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if settled { expanded = false } }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

enum PermissionStatus {
    case granted
    case needed
    case automatic(String)
}

struct PermissionRow: View {
    let number: Int
    let title: String
    let detail: String
    let status: PermissionStatus
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 26, height: 26)
                .overlay(
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                )
                .accessibilityHidden(true)

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

            // Fixed trailing column, so buttons and "Granted" line up down the
            // list instead of sitting wherever the text happens to end.
            Group {
                if let action {
                    Button(action.0, action: action.1)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                } else if case .granted = status {
                    // Sized to sit level with the buttons on the other rows,
                    // rather than reading as a stray caption.
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .imageScale(.medium)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
    }

    /// Green means granted. Anything not yet given is orange, including the
    /// permissions macOS asks for on its own — colouring those green would
    /// claim something that has not happened.
    private var tint: Color {
        if case .granted = status { return .green }
        return .orange
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .granted:
            EmptyView()
        case .needed:
            Text("Needed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        case .automatic:
            EmptyView()
        }
    }
}

// MARK: - Working
