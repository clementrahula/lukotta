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
                    .accessibilityLabel(
                        model.revealCredential
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
                if model.usingSavedCredential {
                    Label("Using the key saved in your Keychain", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Toggle("Remember this key in my Keychain", isOn: $model.rememberCredential)
                    .font(.callout)
                    .padding(.top, 2)

                Text(
                    "The password the drive was locked with, or a 48-digit BitLocker recovery key. Spaces and hyphens in a recovery key are ignored."
                )
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
struct PermissionsPanel: View {
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
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: fullDiskGranted ? "checkmark.shield.fill" : "hand.raised.fill"
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(fullDiskGranted ? Color.green : Color.orange)
                    Text(
                        fullDiskGranted
                            ? "Permissions granted"
                            : "One permission still needs your approval"
                    )
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
                        detail:
                            "Lukotta reads the drive directly in order to unlock it. Only the drive you choose is read.",
                        status: .automatic("Asked by macOS"),
                        action: ("Settings", { model.openFilesAndFoldersSettings() }))

                    PermissionRow(
                        icon: "key.fill",
                        title: "Your administrator password",
                        detail:
                            "Reading a raw disk and mounting a volume both need it. macOS asks once per unlock, and Lukotta never sees it.",
                        status: .automatic("Asked each unlock"),
                        action: nil)

                    PermissionRow(
                        icon: "lock.shield.fill",
                        title: "Full Disk Access",
                        detail: fullDiskGranted
                            ? "Granted. This is what lets Lukotta read the drive at all."
                            : "macOS blocks raw disk reads without it, even for administrators. It is the one permission an app cannot request — it has to be switched on by hand.",
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
        case .granted: return .green
        case .needed: return .orange
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
