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
                Text("About & Help").font(.headline)
                    .accessibilityAddTraits(.isHeader)
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
                            "\(Brand.name) starts a small Linux virtual machine, unlocks the drive inside it, and hands the drive back to Finder. macOS cannot read BitLocker or Linux filesystems. Linux can."
                        )
                    }

                    HelpSection(title: "What it can open") {
                        Bullet(
                            "BitLocker drives, unlocked with the volume password or a 48-digit recovery key"
                        )
                        Bullet(
                            "Windows NTFS drives, including ones Windows left hibernated or not shut down properly"
                        )
                        Bullet("LUKS drives from Linux, both LUKS1 and LUKS2")
                        Bullet(
                            "LVM inside LUKS, as Ubuntu, Debian, Mint and Fedora set it up. Several volumes on one drive all unlock together"
                        )
                        Bullet("ext4, btrfs and XFS filesystems inside them")
                        Bullet(
                            "Virtual machine disks: qcow2, VMDK, VDI, VHD and VHDX, as VMware, VirtualBox, Hyper-V, QEMU and UTM write them"
                        )
                        Bullet(
                            "Raw disk images, and a BitLocker or LUKS volume inside any image, which unlocks like one on a drive"
                        )
                    }

                    HelpSection(title: "Opening a disk image") {
                        Bullet(
                            "Choose File → Open Disk Image, or File → Open Drive to see every disk attached to this Mac and what \(Brand.name) can do with each"
                        )
                        Bullet(
                            "An image opens without an administrator password, and the volume appears in your home folder"
                        )
                        Bullet(
                            "An exFAT image is handed to macOS, which reads and writes that format itself"
                        )
                    }

                    HelpSection(title: "What it cannot open") {
                        Bullet(
                            "Drives sealed to a TPM rather than a password, including Ubuntu's newer hardware-backed encryption"
                        )
                        Bullet("LUKS volumes whose header is stored separately from the drive")
                        Bullet(
                            "FileVault and encrypted disk images, which macOS opens itself"
                        )
                        Bullet(
                            "Images that name another file: a VMware snapshot chain, a differencing VHD, a VHDX with a parent, or a qcow2 with a backing file. \(Brand.name) opens no image that decides which other files get read"
                        )
                        Bullet(
                            "A VHDX that was not shut down cleanly. Open it once in the virtual machine it belongs to, which writes back what it last held"
                        )
                    }

                    HelpSection(title: "Why it appears as a network drive") {
                        Text(
                            "The drive is handed to Finder over a local network connection, so it appears under Locations with a network icon. It reads, writes and ejects like any other drive. macOS offers no way to present it as a local disk."
                        )
                    }

                    HelpSection(title: "Permissions") {
                        Bullet(
                            "Full Disk Access — macOS will not let any app read a drive’s raw contents without it. It cannot be requested, so it has to be switched on by hand"
                        )
                        Bullet(
                            "Removable volumes — requested by macOS the first time a drive is read")
                        Bullet(
                            "Administrator password — asked for once when the background helper is set up, then not again. \(Brand.name) never sees it"
                        )
                    }

                    HelpSection(title: "Requirements") {
                        Bullet("An Apple Silicon Mac. Intel Macs are not supported")
                        Bullet("macOS 15 Sequoia or later")
                        Bullet(
                            "250 MB of disk: 155 MB for the app, 95 MB for the Linux environment it unpacks on first use"
                        )
                        Bullet("30 to 80 MB of RAM per unlocked drive")
                        Bullet("About ten drives can stay unlocked at once")
                    }

                    HelpSection(title: "Licence") {
                        Text(
                            "\(Brand.name) is free software under the GPL, version 3 or later. The mounting is done by anylinuxfs. Complete source for every component is published with each release. The name and the logo are trademarks, and are not covered by that licence."
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
                            // The acute is deliberate: it marks the stress the
                            // sentence goes on to describe. Not the app's name,
                            // which comes from the bundle everywhere else.
                            """
                            Lúkotta is Finnish for “without a lock”, from lukko, a lock, with \
                            the ending -tta marking the absence of something. The stress falls \
                            on the first syllable, as it always does in Finnish.
                            """
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
    case licence = "LICENSE.txt"
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
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .kerning(0.6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 7) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                .offset(y: -2)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
