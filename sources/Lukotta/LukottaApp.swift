// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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

/// Take the daemon down and put it back, so a replaced helper binary is the one
/// actually running.
///
/// The daemon has no KeepAlive and never exits on its own: launchd starts it
/// the first time something asks for its mach service, and it then runs a run
/// loop for ever. Replacing the application therefore leaves the *old* helper
/// resident, answering with whatever methods it was built with. Unregistering
/// removes the job, which ends the process; registering puts it back, and the
/// next call starts the new binary.
///
/// Ordinary updates do not need this — Sparkle replaces the app while the
/// helper is idle and the next launch of it picks the new one up — but a
/// hand-installed build during development does.
private func reinstallHelperIfAsked() {
    guard CommandLine.arguments.contains("--reinstall-helper") else { return }
    let service = SMAppService.daemon(plistName: HelperInfo.plistName)
    try? service.unregister()
    // launchd takes a moment to tear the job down; registering into a job that
    // is still going away puts the status back to notRegistered.
    Thread.sleep(forTimeInterval: 2)
    do {
        try service.register()
    } catch {
        FileHandle.standardError.write(
            Data("could not register the helper: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    Thread.sleep(forTimeInterval: 1)
    switch service.status {
    case .enabled: print("helper re-registered and enabled")
    case .requiresApproval: print("helper re-registered; approve it in Login Items")
    case .notRegistered: print("helper is not registered")
    case .notFound: print("helper not found")
    @unknown default: print("helper status unknown")
    }
    exit(0)
}

/// Ask for a container file and open it.
///
/// No file type filter beyond what macOS will attach: a LUKS container has no
/// extension of its own and is as likely to be called `backup.img` as anything,
/// so refusing by name would refuse the common case. Whether it holds something
/// openable is answered by attaching it and looking.
@MainActor
private func chooseImage(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.title = String(localized: "Open Disk Image")
    panel.prompt = String(localized: "Open")
    panel.message = String(
        localized: "Choose a disk image or container file to open.")
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.openImage(url)
}

/// Talk to the helper and come back, or die trying.
///
/// Both paths: a reply, and an error handler on XPC's own queue. The second is
/// what killed build 232 — the error handler was a main-actor closure and
/// running it anywhere else traps under Swift 6. Nothing here needs a drive, so
/// it can be run any time the helper is registered.
@MainActor
private func checkHelperIfAsked() {
    guard CommandLine.arguments.contains("--check-helper") else { return }
    let client = HelperClient()
    client.refresh()
    print("helper state: \(client.state)")
    guard client.isReady else {
        print("helper not registered; nothing to check")
        exit(0)
    }
    // A device may be named after the flag, so a real drive can be checked
    // without going through the interface: --check-helper /dev/disk4s1.
    let index = CommandLine.arguments.firstIndex(of: "--check-helper") ?? 0
    let device =
        CommandLine.arguments.count > index + 1
            && CommandLine.arguments[index + 1].hasPrefix("/dev/")
        ? CommandLine.arguments[index + 1] : "/dev/disk0s1"
    print("device:      \(device)")

    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let replied = await client.identify(devicePath: device)
        print("reply path:  \(replied.rawValue)")
        let errored = await client.identifyOverABrokenConnection(devicePath: device)
        print("error path:  \(errored.rawValue)")
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    print("both paths returned without trapping")
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
            String(localized: "\(plan.openDrives.count) open drives will be ejected."))
    }
    if plan.helperRegistered {
        detail.append(String(localized: "The background helper will be unregistered."))
    }
    if let mb = plan.guestSizeMB, mb > 0 {
        detail.append(
            String(localized: "The Linux environment will be deleted, freeing about \(mb) MB."))
    }
    detail.append(String(localized: "\(Brand.name) will be moved to the Bin."))

    let alert = NSAlert()
    alert.messageText = String(localized: "Uninstall \(Brand.name)?")
    alert.informativeText = detail.joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Uninstall"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    // Passphrases are the one thing worth asking about rather than deciding.
    // Some are 48-digit recovery keys that exist nowhere else, so the question
    // names the drives instead of offering to delete "some passphrases".
    var passphraseBox: NSButton?
    if !plan.savedPassphrases.isEmpty {
        let names = plan.savedPassphrases.joined(separator: ", ")
        let box = NSButton(
            checkboxWithTitle: String(
                localized:
                    "Also delete \(plan.savedPassphrases.count) saved passphrases (\(names))"),
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

/// Whether this launch was started by the system rather than by a person.
///
/// Whether anybody asked for this launch.
///
/// A person opening an app makes it the active application; launchd starting a
/// login item never does. The catch is when to look: activation does not
/// reliably arrive before launching finishes, and asked at that moment the
/// answer is "nobody" for a launch somebody plainly asked for.
///
/// So the window is made either way and the question is asked again a moment
/// later. Answered wrongly this hides a window that was wanted, which a click
/// in the Dock undoes; the other way round is an app that never appears.
///
/// Not `XPC_SERVICE_NAME`, which looks like the answer and is not: launchd
/// gives every launch a job name of the form `application.<bundle id>.<n>.<n>`,
/// a login item and a double-click alike. Read that way the answer is always
/// "at login", and an app that suppresses its window at every launch puts
/// nothing on screen at all.
enum LaunchContext {
    /// Long enough for activation to arrive, short enough that a window nobody
    /// wanted is gone before it is read.
    static let settle: TimeInterval = 1.5
}

@main
struct LukottaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updater = Updater()
    @AppStorage(MenuBarPreference.key) private var showMenuBarIcon = true

    init() {
        runSmokeTestIfAsked()
        unregisterHelperIfAsked()
        reinstallHelperIfAsked()
        MainActor.assumeIsolated { checkHelperIfAsked() }
        MainActor.assumeIsolated { EndToEnd.runIfAsked() }
        MainActor.assumeIsolated { Snapshots.runIfAsked() }
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
                    // And the log, so the report is already written whenever
                    // somebody reaches for it.
                    model.refreshRecentLog()
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
            // The list's own order, and the list's own names. Sorting the
            // mount points instead gave a menu in a different order from the
            // window behind it, naming drives after the folder they landed in.
            ForEach(model.drives) { drive in
                if let point = model.mountPoint(for: drive) {
                    Button("Eject \(drive.name)") { model.eject(point) }
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
            // The File menu is otherwise removed: there are no documents to
            // make. Opening a container file is the one thing that belongs
            // there, and it is where anyone would look for it.
            CommandGroup(replacing: .newItem) {
                Button("Open Disk Image…") { chooseImage(model) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.canOpenAnother)
                // Where to look when the list is empty and the drive is
                // plainly plugged in.
                Button("Open Drive…") { model.showOpenDrive = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.canOpenAnother)
                // Said once, where both are greyed out, rather than as a
                // failure after a minute of work.
                if !model.canOpenAnother {
                    Text("Eject a drive or an image before opening another.")
                }
            }
            // The standard About panel says the version and the licence and
            // stops there. This one says what the app does, what it can open
            // and what it cannot, so it is the one the menu should reach.
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)") { model.showHelp = true }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Divider()
                Button("Uninstall \(Brand.name)…") { confirmUninstall(model) }
            }
            CommandGroup(replacing: .help) {
                // Named for what it opens rather than for the menu it sits in,
                // so the app menu, the Help menu and the sheet all say the same
                // thing.
                Button("About & Help") { model.showHelp = true }
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

        // Started at login the window goes away again: the drives come back by
        // themselves, the way a disk mounted by macOS does, and nobody asked to
        // see anything. Clicking the app in the Dock brings it back. The scan
        // is started by the window either way, so there is nothing to start
        // here.
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchContext.settle) {
            guard !NSApp.isActive else { return }
            Log.app.notice("nobody asked for this launch; hiding the window")
            NSApp.hide(nil)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemIsPoweringOff = true
        }
    }

    /// Closing the window quits, as it does for any tool used occasionally —
    /// unless the drives are meant to come back by themselves, in which case
    /// the app has to still be here when one is plugged in.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        !RestorePreference.isOn
    }

    /// A mounted drive means a microVM is still running. Quitting without
    /// ejecting would leave it behind, so ask.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !systemIsPoweringOff else { return .terminateNow }

        // Coming straight back is not leaving. The drives are held by the
        // helper and are still there a second later, so there is nothing to
        // decide and asking only gets in the way. Without the helper they would
        // drop, and then the question is a real one.
        if AppModel.wantsRelaunch, let model, MainActor.assumeIsolated({ model.helper.isReady }) {
            return .terminateNow
        }
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
        let one = names.count == 1

        let title: String
        let body: String
        if one {
            title = String(localized: "Quit and leave \u{201C}\(names[0])\u{201D} open?")
            body =
                survives
                ? String(
                    localized:
                        "The drive stays in Finder after \(Brand.name) quits. Eject it there whenever you are finished."
                )
                : String(
                    localized:
                        "The background helper is not set up, so \(Brand.name) is holding the drive open itself. Quitting now disconnects it, and anything still being written would not finish.\n\nOnce the helper is set up, drives stay open on their own."
                )
        } else {
            title = String(localized: "Quit and leave \(names.count) drives open?")
            body =
                survives
                ? String(
                    localized:
                        "They stay in Finder after \(Brand.name) quits. Eject them there whenever you are finished."
                )
                : String(
                    localized:
                        "The background helper is not set up, so \(Brand.name) is holding them open itself. Quitting now disconnects them, and anything still being written would not finish.\n\nOnce the helper is set up, drives stay open on their own."
                )
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body

        // Leaving them open is what most people want when they close a window,
        // and it is the one choice here that cannot lose anything: the drives
        // keep working. Ejecting is the deliberate act, so it does not get the
        // return key.
        if survives { alert.addButton(withTitle: String(localized: "Leave Open")) }
        alert.addButton(withTitle: String(localized: "Eject and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Cancel sits where AppKit puts it. NSAlert offers no way to hold it
        // apart from the two answers, and reaching into the stack it builds
        // fights a layout that is measured before the reach. Doing it properly
        // would mean building this dialog by hand, which is not worth it on the
        // path that quits the app.

        let ejectButton: NSApplication.ModalResponse =
            survives ? .alertSecondButtonReturn : .alertFirstButtonReturn
        let answer = alert.runModal()

        if survives, answer == .alertFirstButtonReturn { return .terminateNow }
        let eject = answer == ejectButton
        // Turning the quit down turns the relaunch down with it, or the next
        // quit would reopen the app for no reason anyone would remember.
        if !eject { AppModel.wantsRelaunch = false }
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

        // Here rather than beside the request, so a quit the user turned down
        // does not leave a second copy behind.
        guard AppModel.wantsRelaunch else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
    }
}
