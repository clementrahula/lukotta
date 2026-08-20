import AppKit
import LukottaCore
import SwiftUI

// MARK: - Help

/// How the app works, what it supports, and what it cannot do.
///
/// Also the only route to the licence and third-party notices, which ship in
/// the bundle — for a GPL application those need to be reachable, not just
/// present.
struct HelpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var document: BundledDocument?

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
                        Text(
                            "Lukotta starts a small Linux virtual machine, unlocks the drive inside it, and shares the result back to Finder over a local connection. macOS has no built-in support for BitLocker or Linux filesystems, so the work happens in Linux, where it is well supported."
                        )
                        Text(
                            "Nothing is installed on your Mac. The engine ships inside the app, no drive is written to unless you write to it, and nothing leaves your machine."
                        )
                    }

                    HelpSection(title: "What it can open") {
                        Bullet(
                            "BitLocker drives, unlocked with the volume password or a 48-digit recovery key"
                        )
                        Bullet(
                            "Windows NTFS drives, including ones Windows left in a hibernated or unclean state"
                        )
                        Bullet("LUKS drives from Linux, both LUKS1 and LUKS2")
                        Bullet(
                            "LVM inside LUKS, the layout Ubuntu, Debian, Mint and Fedora use. If the container holds several volumes, all of them are unlocked together"
                        )
                        Bullet("ext4, btrfs and XFS filesystems inside those containers")
                    }

                    HelpSection(title: "What it cannot open") {
                        Bullet(
                            "Drives sealed to a TPM rather than a password, including Ubuntu's newer hardware-backed encryption"
                        )
                        Bullet("LUKS volumes whose header is stored separately from the drive")
                    }

                    HelpSection(title: "Why it appears as a network drive") {
                        Text(
                            "The unlocked volume is shared back to Finder over a local network connection, so macOS files it under Locations and shows it with a network icon. It reads and writes normally, and ejecting works as usual. macOS provides no way to present it as a local disk."
                        )
                    }

                    HelpSection(title: "Permissions") {
                        Bullet(
                            "Full Disk Access — macOS blocks reading a drive at the raw level without it. It is the one permission an app cannot request, so it must be switched on by hand"
                        )
                        Bullet(
                            "Removable volumes — requested by macOS the first time a drive is read")
                        Bullet(
                            "Administrator password — required once per unlock to read the disk and mount the volume. Lukotta never sees it"
                        )
                    }

                    HelpSection(title: "Licence") {
                        Text(
                            "Lukotta is free software under the GPL, version 3 or later. It is built on anylinuxfs, which does the hard part. Complete source for every component is published alongside each release."
                        )
                        HStack(spacing: 10) {
                            Button("Licence") { document = .licence }
                            Button("Third-Party Notices") { document = .notices }
                            Button("Website") { model.open("https://lukotta.rahula.dev") }
                            Button("Source") {
                                model.open("https://github.com/clementrahula/lukotta")
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }

                    HelpSection(title: "Requirements") {
                        Bullet("An Apple Silicon Mac. Intel Macs are not supported")
                        Bullet("macOS 26 or later")
                        Bullet(
                            "250 MB of disk: 155 MB for the app, 95 MB for the Linux environment it unpacks on first use"
                        )
                        Bullet(
                            "30 to 80 MB of RAM per unlocked drive, depending on how many volumes it holds"
                        )
                        Bullet("Each unlocked drive runs its own Linux virtual machine")
                    }

                    HelpSection(title: "Author") {
                        Text("Clement Rahula")
                        HStack(spacing: 10) {
                            Button("lukotta@rahula.dev") { model.open("mailto:lukotta@rahula.dev") }
                            Button("rahula.dev") { model.open("https://rahula.dev") }
                        }
                        .controlSize(.small)
                    }

                    HelpSection(title: "The name") {
                        Text(
                            "Lúkotta is Finnish for “without a lock”, from lukko, a lock, with the "
                                + "ending -tta marking the absence of something. The stress falls on "
                                + "the first syllable, as it always does in Finnish."
                        )
                    }

                    Text(version).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(22)
            }
        }
        .frame(width: 580, height: 560)
        .sheet(item: $document) { DocumentSheet(document: $0) }
    }
}

/// A document shipped inside the bundle.
enum BundledDocument: String, Identifiable {
    case licence = "LICENSE"
    case notices = "THIRD_PARTY_NOTICES.md"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .licence: return "GNU General Public License"
        case .notices: return "Third-Party Notices"
        }
    }
}

/// Shows a bundled document without handing the user off to another app.
///
/// These are licence texts a GPL application has to make available; opening
/// them in whatever happens to own .md files is a poor substitute for showing
/// them where they were asked for.
struct DocumentSheet: View {
    let document: BundledDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()

            ScrollView {
                Group {
                    if text.isEmpty {
                        Text("Not found in this build.").foregroundStyle(.secondary)
                    } else if document == .licence {
                        // The GPL is a legal text with meaningful line breaks;
                        // reflowing it would be wrong.
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        MarkdownView(source: text).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: 720, height: 620)
        .task {
            guard
                let url = Bundle.main.resourceURL?
                    .appendingPathComponent(document.rawValue),
                let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return }
            text = contents
        }
    }
}

struct HelpSection<Content: View>: View {
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

struct Bullet: View {
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
