// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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
        noRoomForIt
            || (model.credential.isEmpty && !model.usingSavedCredential
                && !model.chosenDriveIsOpenAlready)
    }

    /// Nowhere left to serve this drive from.
    ///
    /// Reachable even though every way in is shut at the ceiling: this screen
    /// can be standing open while the last drive somebody else asked for
    /// finishes mounting, or while one comes back at login. The buttons say so
    /// rather than bouncing whoever presses them back to the list.
    private var noRoomForIt: Bool {
        !model.canOpenAnother && model.mountPoint(for: drive) == nil
    }
    @State private var capsLockOn = false
    @State private var capsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if noRoomForIt {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(
                                "\(model.capacity.openCount) drives or images are open. You can only have \(model.capacity.limitCount) open at the same time. Eject one to open another."
                            )
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35))
                        )
                        .accessibilityElement(children: .combine)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            model.chosenDriveIsOpenAlready
                                ? "Open “\(isolated(drive.name))”"
                                : "Unlock “\(isolated(drive.name))”"
                        )
                        .font(.title3.weight(.semibold))
                        Text(verbatim: "\(drive.sizeDescription) · \(drive.devicePath)")
                            .font(.caption).foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }

                    // A refusal that sent the reader back here rather than to
                    // the permission screen says so, the panel below being
                    // where the setting is. Drawn as the drive list draws it.
                    if let notice = model.notice {
                        Label(notice, systemImage: "bolt.horizontal.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Only for something that really has no password. Written
                    // as "not BitLocker" when those were the only three
                    // formats, it began calling LUKS containers unencrypted
                    // the moment the probe learned to recognise one.
                    if let format = model.chosenFormat, format.isUnencrypted {
                        FormatNote()
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
                                .environment(\.layoutDirection, .leftToRight)
                                .focused($focused)
                                // The same request the default button makes:
                                // a format that cannot be written is opened
                                // read-only whichever way it was asked for.
                                .onSubmit {
                                    model.unlock(drive, readOnly: !model.chosenIsWritable)
                                }
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

/// What is still to be done before a drive can be opened, and how to do it.
///
/// Only that. A permission already granted is not a step, and a permission
/// macOS asks for by itself when the moment comes is not one either: neither
/// leaves the reader anything to do, and a line with an empty space where a
/// button would be asks a question it does not answer. With nothing
/// outstanding there is no panel at all.
struct PermissionsPanel: View {
    @EnvironmentObject var model: AppModel

    private struct Step {
        let title: String
        let detail: String
        let status: PermissionStatus
        let action: (String, () -> Void)
    }

    private var removable: Step? {
        guard model.removableAccess == false else { return nil }
        return Step(
            title: appString("Seeing connected drives"),
            // A bare button into a settings pane is a dead end. Say what to do
            // once it opens.
            detail: appString(
                "Was refused. In Files & Folders, switch on Removable Volumes for \(Brand.name), then come back."
            ),
            status: .needed,
            action: (appString("Settings"), { model.openFilesAndFoldersSettings() }))
    }

    private var administrator: Step? {
        switch model.helper.state {
        case .ready:
            return nil
        case .awaitingApproval:
            return Step(
                title: appString("Administrator password"),
                detail: appString(
                    "Reading a raw disk and mounting a filesystem are actions only an administrator can do. Approve \(Brand.name) in Login Items to finish."
                ),
                status: .needed,
                action: (appString("Approve"), { model.helper.openLoginItemsSettings() }))
        default:
            return Step(
                title: appString("Administrator password"),
                detail: appString(
                    "Reading a raw disk and mounting a filesystem are actions only an administrator can do. \(Brand.name) never sees your password."
                ),
                status: .automatic(appString("Asked each time")),
                action: (appString("Set Up"), { model.helper.install() }))
        }
    }

    private var fullDisk: Step? {
        guard !model.hasFullDiskAccess else { return nil }
        return Step(
            title: appString("Full Disk Access"),
            detail: appString(
                "Lets \(Brand.name) read the encrypted data itself. macOS blocks this without it, even for administrators, and it cannot be requested: it has to be switched on by hand."
            ),
            status: .needed,
            action: (appString("Open Settings"), { model.openPrivacySettings() }))
    }

    private var steps: [Step] { [removable, administrator, fullDisk].compactMap { $0 } }

    var body: some View {
        // Numbered over what is shown, so the list reads 1, 2, 3 whichever of
        // them is outstanding.
        let steps = steps
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Some permissions are still needed")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    PermissionRow(
                        number: index + 1, title: step.title, detail: step.detail,
                        status: step.status, action: step.action)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        }
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
    let action: (String, () -> Void)

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

            // Fixed trailing column, so the buttons line up down the list
            // instead of sitting wherever the text happens to end.
            Button(action.0, action: action.1)
                .controlSize(.small)
                .buttonStyle(.bordered)
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
            return String(localized: "\(container.name) image can only be opened read-only")
        }
        return String(localized: "Writing to this image format is untested")
    }

    /// Whether this note is the one about a driver built here, as opposed to
    /// the one about a format that is only read.
    private var aboutOurOwnWriting: Bool { container.writtenByOurOwnDriver }

    private var detail: String {
        if !container.isWritable {
            return String(
                localized: "\(Brand.name) does not yet support writing to this file format."
            )
        }
        return String(localized: "Open it read-only to copy files out, or back it up first.")
    }

    private var tint: Color { aboutOurOwnWriting ? .orange : .blue }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: aboutOurOwnWriting
                    ? "exclamationmark.triangle.fill" : "info.circle.fill"
            )
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

/// Says what an unencrypted drive is, before anyone looks for a password.
///
/// Only shown for a drive that turned out not to be locked. Lukotta can still
/// open it, which is what gives a Windows disk the read and write access macOS
/// does not, so this is worded as an explanation and not as a refusal.
private struct FormatNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Which filesystem it is has no bearing on what to do next.
                // The buttons below say what opening it will do.
                Text("This drive is not encrypted.").font(.callout.weight(.medium))
                Text("There is no password to enter.")
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
