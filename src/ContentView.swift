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
                case .mounted(let d, let p): MountedView(drive: d, mountPoint: p)
                case .failed(let d, let s, let detail):
                    FailureView(drive: d, summary: s, detail: detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Chrome

private struct Header: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("BitLocker Mounter").font(.headline)
                Text("Open BitLocker-encrypted drives on macOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time setup needed").font(.title3.weight(.semibold))
                    Text("macOS will not let any app read an encrypted disk without permission — not even with an administrator password.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Step(number: 1, text: "Open Privacy & Security → Full Disk Access.")
                Step(number: 2, text: "Click + and add BitLocker Mounter, then switch it on.")
                Step(number: 3, text: "Quit BitLocker Mounter and open it again.")
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
                title: "No BitLocker drives found",
                message: "Connect the encrypted USB drive and choose Rescan. If it is already connected, macOS may have it mounted — eject it in Finder first.",
                actionTitle: "Rescan",
                action: model.rescan)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Select a drive to unlock")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.drives) { drive in
                            DriveRow(drive: drive) { model.choose(drive) }
                        }
                    }
                }
                HStack {
                    Text("Drives of type “Microsoft Basic Data” are shown. Plain NTFS drives look identical to BitLocker ones until unlocking is attempted.")
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.lock")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(.body.weight(.medium))
                    Text(drive.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unlock

private struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @FocusState private var focused: Bool

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
                Text("Either the password the drive was locked with, or the 48-digit recovery key. Spaces and hyphens in a recovery key are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InfoBox(icon: "lock.badge.clock",
                    text: "macOS will ask for your administrator password once. Reading an encrypted disk requires it. Nothing is installed on your Mac.")

            Spacer()
            HStack {
                Button("Back", action: model.backToDrives)
                Spacer()
                Button("Unlock") { model.unlock(drive) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.credential.isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Working

private struct WorkingView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlocking “\(drive.name)”…").font(.body.weight(.medium))
                    Text(model.statusLines.last ?? "Starting the mounting engine…")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            InfoBox(icon: "clock",
                    text: "The first unlock after connecting a drive takes longest — a small Linux virtual machine has to start before the drive can be read.")

            DisclosureGroup("Details", isExpanded: $showDetail) {
                LogView(lines: model.statusLines)
            }
            .font(.caption)
            Spacer()
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
                    text: "The drive appears in the Finder sidebar under Locations. Eject it there, or with the button below, before unplugging it.")

            Spacer()
            HStack {
                Button("Show in Finder") { model.revealInFinder(mountPoint) }
                Spacer()
                Button("Eject") { model.eject(mountPoint) }
                Button("Done", action: model.rescan).keyboardShortcut(.defaultAction)
            }
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
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(height: 150)
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
