import AppKit
import LukottaCore
import ServiceManagement
import SwiftUI

/// Prove the binary starts before it is released.
///
/// Reaching `main` means dyld resolved every library, including the embedded
/// Sparkle framework — the one failure an update cannot undo, because the
/// update installs correctly and only then does the app refuse to run. Exits
/// straight away rather than raising a window.
private func runSmokeTestIfAsked() {
    guard CommandLine.arguments.contains("--smoke-test") else { return }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    guard let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String,
        !key.isEmpty, !key.hasPrefix("__")
    else {
        FileHandle.standardError.write(Data("no Sparkle public key embedded\n".utf8))
        exit(1)
    }
    print("Lukotta \(version) (\(build)) started, update key present")
    exit(0)
}

/// Where the menu bar preference lives, so the setting and the scene that reads
/// it cannot drift apart over a spelled-out key.
enum MenuBarPreference {
    static let key = "dev.lukotta.showMenuBarIcon"
}

/// Unregister the privileged helper and exit.
///
/// Dragging the app to the Bin leaves the daemon registered, because launchd
/// knows about the service and not about the folder it came from. Only the app
/// that registered it can withdraw it, so uninstalling has to go through here.
private func unregisterHelperIfAsked() {
    guard CommandLine.arguments.contains("--uninstall-helper") else { return }
    let service = SMAppService.daemon(plistName: HelperInfo.plistName)
    do {
        try service.unregister()
        print("Unregistered \(HelperInfo.machServiceName)")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("could not unregister the helper: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

/// Ask before removing anything, describing this Mac rather than the general
/// case, then show the removal happening.
@MainActor
private func confirmUninstall(_ model: AppModel) {
    let plan = Uninstall.survey()

    var detail: [String] = []
    if !plan.openDrives.isEmpty {
        detail.append(
            plan.openDrives.count == 1
                ? "The open drive will be ejected."
                : "\(plan.openDrives.count) open drives will be ejected.")
    }
    if plan.helperRegistered { detail.append("The background helper will be unregistered.") }
    if let mb = plan.guestSizeMB, mb > 0 {
        detail.append("The Linux environment will be deleted, freeing about \(mb) MB.")
    }
    detail.append("\(Brand.name) will be moved to the Bin.")

    let alert = NSAlert()
    alert.messageText = "Uninstall \(Brand.name)?"
    alert.informativeText = detail.joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")

    // Passphrases are the one thing worth asking about rather than deciding.
    // Some are 48-digit recovery keys that exist nowhere else, so the question
    // names the drives instead of offering to delete "some passphrases".
    var passphraseBox: NSButton?
    if !plan.savedPassphrases.isEmpty {
        let names = plan.savedPassphrases.joined(separator: ", ")
        let box = NSButton(
            checkboxWithTitle:
                plan.savedPassphrases.count == 1
                ? "Also delete the saved passphrase for \(names)"
                : "Also delete \(plan.savedPassphrases.count) saved passphrases (\(names))",
            target: nil, action: nil)
        box.state = .off
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 40))
        box.frame = NSRect(x: 0, y: 0, width: 380, height: 40)
        (box.cell as? NSButtonCell)?.wraps = true
        wrap.addSubview(box)
        alert.accessoryView = wrap
        passphraseBox = box
    }

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let removingPassphrases = passphraseBox?.state == .on
    model.uninstallSteps = Uninstall.steps(for: plan, removingPassphrases: removingPassphrases)
    model.uninstallFailure = nil
    model.isUninstalling = true

    Uninstall.perform(
        plan,
        removingPassphrases: removingPassphrases,
        advance: { index in
            if model.uninstallSteps.indices.contains(index) {
                model.uninstallSteps[index].done = true
            }
        },
        completion: { failure in
            model.uninstallFailure = failure
            model.uninstallFinished = true
        })
}

@main
struct LukottaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()
    @AppStorage(MenuBarPreference.key) private var showMenuBarIcon = true

    init() {
        runSmokeTestIfAsked()
        unregisterHelperIfAsked()
        // Before anything else: a build that has failed to start twice already
        // does not get a third go at it.
        guard Rollback.evaluateLaunch() else { exit(0) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    // Without the helper the virtual machine is this process's
                    // child, so replacing the app would take the drive with it.
                    updater.holdsADrive = {
                        MainActor.assumeIsolated { model.hasOpenDrive && !model.helper.isReady }
                    }
                    model.onAllDrivesClosed = { [weak updater] in
                        updater?.installPostponedUpdate()
                    }
                    model.start()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    // Permissions are granted elsewhere, so look again on the
                    // way back rather than trusting a stale reading.
                    model.refreshPermissions()
                }
        }
        .windowResizability(.contentMinSize)
        // Present only while something is open, so it does not clutter the menu
        // bar for a tool used occasionally.
        // The systemImage initialiser, not a custom label: a label built from a
        // view is rendered as-is, without the template treatment and sizing the
        // menu bar applies to a symbol, and comes out heavy and misaligned.
        MenuBarExtra(
            Brand.name, systemImage: "externaldrive.fill",
            isInserted: Binding(
                get: { showMenuBarIcon && !model.openMounts.isEmpty },
                set: { _ in })
        ) {
            ForEach(Array(model.openMounts.values.sorted()), id: \.self) { path in
                Button("Eject \((path as NSString).lastPathComponent)") {
                    model.eject(path)
                }
            }
            Divider()
            Button("Open \(Brand.name)") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit \(Brand.name)") { NSApp.terminate(nil) }
        }

        Settings {
            SettingsView()
                .environmentObject(updater)
                .environmentObject(model)
        }

        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Divider()
                Button("Uninstall \(Brand.name)…") { confirmUninstall(model) }
            }
            CommandGroup(replacing: .help) {
                Button("\(Brand.name) Help") { model.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Report an Issue…") { model.showReport = true }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    /// Set once the Mac has started logging out, restarting or shutting down.
    ///
    /// macOS asks each app to quit and waits only a moment. An app that raises
    /// a dialog and answers "cancel" stops the restart and makes the user hunt
    /// down which app did it. An open drive is never worth that: the helper
    /// keeps the mount alive on its own, so quitting quietly loses nothing.
    private var systemIsPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Here rather than in the App's init, where NSApp does not exist yet.
        Appearance.current.apply()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemIsPoweringOff = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// A mounted drive means a microVM is still running. Quitting without
    /// ejecting would leave it behind, so ask.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !systemIsPoweringOff else { return .terminateNow }
        guard let model, MainActor.assumeIsolated({ model.hasOpenDrive }) else {
            return .terminateNow
        }

        // Without the helper the virtual machine is tied to this process, so
        // leaving a drive open would drop it the moment the app quits, and macOS
        // would report the connection as interrupted. Only offer that choice
        // when the drive would actually survive.
        let survives = MainActor.assumeIsolated { model.helper.isReady }

        let names = MainActor.assumeIsolated {
            model.openMounts.values.sorted().map { ($0 as NSString).lastPathComponent }
        }
        let subject =
            names.count == 1 ? "\u{201C}\(names[0])\u{201D}" : "\(names.count) drives"

        let one = names.count == 1
        let it = one ? "it" : "them"

        var body: String
        if survives {
            body =
                "\(one ? "The drive stays" : "They stay") in Finder after \(Brand.name) quits. "
                + "Eject \(it) there whenever you are finished."
        } else {
            body =
                "The background helper is not set up, so \(Brand.name) is holding "
                + "\(one ? "the drive" : it) open itself. Quitting now disconnects \(it), and "
                + "anything still being written would not finish.\n\n"
                + "Once the helper is set up, drives stay open on their own."
        }

        let alert = NSAlert()
        alert.messageText = "Quit and leave \(subject) open?"
        alert.informativeText = body

        // Leaving them open is what most people want when they close a window,
        // and it is the one choice here that cannot lose anything: the drives
        // keep working. Ejecting is the deliberate act, so it does not get the
        // return key.
        if survives { alert.addButton(withTitle: "Leave Open") }
        alert.addButton(withTitle: "Eject and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Cancel sits where AppKit puts it. Setting the stack's spacing to hold
        // it apart from the two answers either left the gap's height empty under
        // it, because the alert is measured before the spacing is set, or
        // collapsed the alert entirely when that measurement was forced. Getting
        // it would mean building this dialog by hand, which is not worth it on
        // the path that quits the app.

        let ejectButton: NSApplication.ModalResponse =
            survives ? .alertSecondButtonReturn : .alertFirstButtonReturn
        let answer = alert.runModal()

        if survives, answer == .alertFirstButtonReturn { return .terminateNow }
        let eject = answer == ejectButton
        if eject {
            MainActor.assumeIsolated {
                model.ejectAll { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        return .terminateCancel
    }

    /// Remove this session's private workspace so the app leaves nothing behind.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanUp() }
    }
}
