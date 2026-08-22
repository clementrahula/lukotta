import AppKit
import LukottaCore
import SwiftUI

// MARK: - Unlock

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @FocusState private var focused: Bool

    /// What the button that opens the drive says.
    ///
    /// "Open", not "Unlock", for a drive that was never locked; and where the
    /// format cannot be written, the one button says what it will do.
    private var openButtonTitle: String {
        if !model.chosenIsWritable {
            return model.chosenDriveIsOpenAlready
                ? String(localized: "Open Read-Only") : String(localized: "Unlock Read-Only")
        }
        return model.chosenDriveIsOpenAlready
            ? String(localized: "Open") : String(localized: "Unlock")
    }

    /// Neither button can be pressed until there is something to open with: a
    /// credential typed, one remembered, or a drive that needs none.
    private var nothingToOpenWith: Bool {
        model.credential.isEmpty && !model.usingSavedCredential
            && !model.chosenDriveIsOpenAlready
    }
    @State private var capsLockOn = false
    @State private var capsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            model.chosenDriveIsOpenAlready
                                ? "Open “\(drive.name)”" : "Unlock “\(drive.name)”"
                        )
                        .font(.title3.weight(.semibold))
                        Text(verbatim: "\(drive.sizeDescription) · \(drive.devicePath)")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Only for something that really has no password. Written
                    // as "not BitLocker" when those were the only three
                    // formats, it began calling LUKS containers unencrypted
                    // the moment the probe learned to recognise one.
                    if let format = model.chosenFormat, format.isUnencrypted {
                        FormatNote(format: format)
                    }

                    // What may be done with the file itself, as opposed to what
                    // is inside it. Only for an image, and only where there is
                    // something worth saying.
                    if let container = model.chosenContainer, container != .raw {
                        ImageNote(container: container)
                    }

                    if model.chosenDriveIsOpenAlready {
                        // No field at all. Asking for a password beside a
                        // sentence saying there is none to give is worse than
                        // saying nothing.
                        EmptyView()
                    } else if model.usingSavedCredential {
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
                // A drive with a passphrase to type came from the list, so the
                // way out is back to it. One with nothing to type is on this
                // screen only to be asked read-write or read-only, and the way
                // out of a question is to cancel it.
                Button(
                    model.chosenDriveIsOpenAlready ? "Cancel" : "Back", action: model.backToDrives)
                Spacer()
                // "Open", not "Unlock", for a drive that was never locked. The
                // read-only choice sits beside each, and is never the default:
                // the drive opens writable unless read-only is chosen.
                //
                // Where the format cannot be written at all, the read-only
                // button is the only one: offering to open something writable
                // that will open read-only anyway is worse than saying so.
                if model.chosenIsWritable {
                    Button(
                        model.chosenDriveIsOpenAlready ? "Open Read-Only" : "Unlock Read-Only"
                    ) {
                        model.unlock(drive, readOnly: true)
                    }
                    .disabled(nothingToOpenWith)
                }
                Button(openButtonTitle) { model.unlock(drive, readOnly: !model.chosenIsWritable) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nothingToOpenWith)
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
            return appString(
                "Was refused. In Files and Folders, switch on Removable Volumes for \(Brand.name), then come back."
            )
        }
        return appString("Lets \(Brand.name) see the drives you plug in.")
    }

    private var removableStatus: PermissionStatus {
        switch model.removableAccess {
        case true: return .granted
        case false: return .needed
        default: return .automatic(appString("Asked when needed"))
        }
    }

    /// Only rows that are actually granted show "Granted"; the rest show a
    /// button or a neutral note, never both.

    private var helperDetail: String {
        switch model.helper.state {
        case .ready:
            return appString(
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do."
            )
        case .awaitingApproval:
            return appString(
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do. Approve \(Brand.name) in Login Items to finish."
            )
        default:
            return appString(
                "Reading a raw disk and mounting a filesystem are actions only an administrator can do. \(Brand.name) never sees your password."
            )
        }
    }

    private var helperStatus: PermissionStatus {
        switch model.helper.state {
        case .ready: return .granted
        case .awaitingApproval: return .needed
        default: return .automatic(appString("Asked each time"))
        }
    }

    private var helperAction: (String, () -> Void)? {
        switch model.helper.state {
        case .ready: return nil
        case .awaitingApproval:
            return (appString("Approve"), { model.helper.openLoginItemsSettings() })
        default: return (appString("Set Up"), { model.helper.install() })
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
                        title: appString("Seeing connected drives"),
                        detail: removableDetail,
                        status: removableStatus,
                        action: model.removableAccess == false
                            ? (appString("Settings"), { model.openFilesAndFoldersSettings() })
                            : nil)

                    PermissionRow(
                        number: 2,
                        title: appString("Administrator password"),
                        detail: helperDetail,
                        status: helperStatus,
                        action: helperAction)

                    PermissionRow(
                        number: 3,
                        title: appString("Full Disk Access"),
                        detail: fullDiskGranted
                            ? appString("Lets \(Brand.name) read the encrypted data itself.")
                            : appString(
                                "Lets \(Brand.name) read the encrypted data itself. macOS blocks this without it, even for administrators, and it cannot be requested: it has to be switched on by hand."
                            ),
                        status: fullDiskGranted ? .granted : .needed,
                        action: fullDiskGranted
                            ? nil
                            : (appString("Open Settings"), { model.openPrivacySettings() }))
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
                    Text(verbatim: "\(number)")
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

/// Says what an unencrypted drive is, before anyone looks for a password.
///
/// Only shown for a drive that turned out not to be locked. Lukotta can still
/// What can be done with the image file itself.
///
/// Two things are worth saying before anything is opened. A VHDX is read and
/// never written here, so a person expecting to save into one should know
/// before they start. The other formats are written by drivers built for this
/// application, which is worth saying plainly: they are tested against qemu-img
/// and they are newer than the rest of the app, and someone who only wants to
/// copy files out loses nothing by opening the image read-only.
private struct ImageNote: View {
    let container: ContainerFormat

    private var title: String {
        if !container.isWritable {
            return String(localized: "A \(container.name) opens read-only")
        }
        return String(localized: "Writing to a \(container.name) is new")
    }

    private var detail: String {
        if !container.isWritable {
            return String(
                localized:
                    "\(Brand.name) reads this format and does not write it: changing one means writing to its log first, which it does not do. Nothing in the file can change."
            )
        }
        return String(
            localized:
                "\(Brand.name) writes this format with a driver of its own, checked against qemu-img, which has written these formats for years. It is tested, and it is newer than the rest of the app. If you only need to copy files out, open it read-only and the file cannot change."
        )
    }

    private var tint: Color { container.isWritable ? .orange : .blue }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: container.isWritable ? "pencil.circle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

/// open it — that is what gives a Windows disk read and write access macOS does
/// not — so this is worded as an explanation rather than as a refusal.
private struct FormatNote: View {
    let format: VolumeFormat

    /// Exhaustive on purpose. The old `default` said "plain NTFS" for anything
    /// it did not recognise, which is how a LUKS container came to be described
    /// as unencrypted NTFS.
    private var title: String {
        switch format {
        case .ntfs: return String(localized: "This drive is plain NTFS, and is not encrypted.")
        case .exfat: return String(localized: "This drive is exFAT, and is not encrypted.")
        case .ext, .btrfs, .xfs:
            return String(localized: "This drive holds a Linux filesystem, and is not encrypted.")
        case .bitlocker, .luks, .unknown:
            // Never shown: the note is only put up for a format with nothing to
            // unlock. Stated rather than defaulted, so adding a format has to
            // decide which of the two it is.
            return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(
                    "There is no password to enter. Open it to read and write to it, which macOS on its own cannot do, or open it read-only to leave it untouched."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}
