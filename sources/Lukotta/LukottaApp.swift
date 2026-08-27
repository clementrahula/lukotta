// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import ServiceManagement
import SwiftUI

/// Answer the update watcher: this build starts.
///
/// Narrower than `--smoke-test`, and deliberately so. Reaching this line means
/// dyld resolved every library and our own code ran, which is the one thing
/// the watcher beside the app cannot find out by looking at the bundle. It
/// says nothing about whether a window ever appears — that is the app's own
/// question, asked over three launches — and it leaves the launch record
/// alone, because a build that starts and then hangs is what that record is
/// for.
///
/// First, before anything at all: the question is whether this binary runs,
/// and every line put in front of it is a line that could answer no for some
/// other reason.
private func answerVerifyLaunchIfAsked() {
    guard CommandLine.arguments.contains("--verify-launch") else { return }
    exit(0)
}

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
    // Starting is what the shim in front of the app is waiting to hear: it
    // counts launches and has no way of its own to tell a working one from a
    // window that never appeared. The release script runs this against every
    // build, so an update proves itself here before anybody receives it.
    Rollback.confirmHealthy()
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
    static let key = "com.lukotta.showMenuBarIcon"
}

/// The menu bar item.
///
/// AppKit rather than `MenuBarExtra`. A MenuBarExtra in this app sends SwiftUI
/// into rebuilding the main menu without stopping the moment it is inserted --
/// a gigabyte every ten seconds, and a beachball -- whether it is inserted from
/// a condition or left in place, and whether its contents read the model or a
/// snapshot of it. An NSStatusItem is placed by AppKit in the menu bar, which
/// is where a menu bar item goes.
///
/// It was not drawn for a while, and none of that was this code's doing: the
/// bundle used to start a C launcher which handed over to the app with execv,
/// and macOS gives no menu bar item to a process whose running image is not
/// the executable the bundle declares. The item was made, registered, listed
/// by accessibility with the right menu -- and left at x = -1 in a window no
/// pixels high. Nothing here can work around that, so the launcher moved.
@MainActor
final class MenuBarItem {
    static let shared = MenuBarItem()
    private var item: NSStatusItem?
    private var eject: ((String) -> Void)?

    /// - Parameter drives: what to offer to eject, in the order the list shows.
    func update(drives: [AppModel.Ejectable], eject: @escaping (String) -> Void) {
        self.eject = eject
        let wanted = UserDefaults.standard.object(forKey: MenuBarPreference.key) as? Bool ?? true
        guard wanted else {
            putAway()
            return
        }
        let fresh = item == nil
        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        // Named, so that dragging it out of the menu bar is remembered as
        // itself rather than under whichever number AppKit handed out this
        // launch. And set once: forcing it true on every scan would put back
        // an item somebody had just dragged away, which is the app arguing.
        item.autosaveName = "menu-bar"
        if fresh { item.isVisible = true }
        if let button = item.button {
            let symbol = NSImage(
                systemSymbolName: "externaldrive.fill", accessibilityDescription: Brand.name)
            symbol?.isTemplate = true
            button.image = symbol
            // Never nothing. A button with neither an image nor a title has no
            // width, which is an item present in every way except on screen.
            if symbol == nil { button.title = Brand.name }
            button.toolTip = Brand.name
        }

        hasSomethingToEject = !drives.isEmpty
        let menu = NSMenu()
        for drive in drives {
            let entry = NSMenuItem(
                title: String(localized: "Eject \(drive.name)"),
                action: #selector(MenuBarItem.ejectChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = drive.point
            menu.addItem(entry)
        }
        if !drives.isEmpty { menu.addItem(.separator()) }
        let show = NSMenuItem(
            title: String(localized: "Open \(Brand.name)"),
            action: #selector(MenuBarItem.bringToFront), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        // The setting for this item, in the item itself. Somebody who wants it
        // gone is looking at it, not at a settings window.
        let hide = NSMenuItem(
            title: String(localized: "Hide Menu Bar Icon"),
            action: #selector(MenuBarItem.hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        // Named for what it does. Quitting from here while a drive is open
        // would leave it served by something nobody can reach any more, so it
        // ejects -- in the words the dialog's own button uses for that act,
        // rather than a second name for one thing.
        //
        // Quitting through a selector of our own rather than through
        // `terminate:`. macOS draws a symbol beside the standard actions, and
        // one item in three carrying a glyph indents the other two off the
        // edge of it -- a menu that looks like it lost an icon rather than one
        // that never had any.
        let quit = NSMenuItem(
            title: drives.isEmpty
                ? String(localized: "Quit \(Brand.name)")
                : String(localized: "Eject and Quit"),
            action: #selector(MenuBarItem.quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func ejectChosen(_ sender: NSMenuItem) {
        guard let point = sender.representedObject as? String else { return }
        eject?(point)
    }

    @objc private func hide() {
        // Through the same setting the settings window writes, so the two say
        // the same thing about it afterwards.
        UserDefaults.standard.set(false, forKey: MenuBarPreference.key)
        putAway()
    }

    /// Take the item out of the menu bar, whoever asked.
    private func putAway() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        // It was the whole of the app there was: no window, no Dock icon, and
        // now nothing in the menu bar either. Quitting is the only honest end
        // to that, and it goes through the usual question about open drives.
        if isTheWholeApp { NSApp.terminate(nil) }
    }

    @objc private func quit() {
        // The item says what it will do, so it is not worth a dialog asking
        // the same question again with a third answer -- and "leave it open"
        // is not on offer from a menu that is about to stop existing.
        askedToEjectAndQuit = hasSomethingToEject
        NSApp.terminate(nil)
    }

    /// Set while a quit came from this menu, where the answer is already given.
    /// Read once and cleared, so a quit that does not go through does not
    /// answer the next one on its behalf.
    func tookTheMenuBarsAnswer() -> Bool {
        defer { askedToEjectAndQuit = false }
        return askedToEjectAndQuit
    }

    private var askedToEjectAndQuit = false

    /// What the menu last offered to eject, which is what its quit item is
    /// named after.
    private var hasSomethingToEject = false

    /// Whether there is an item in the menu bar somebody can actually reach.
    ///
    /// Not "was one asked for": the setting is one way to be rid of it and
    /// dragging it out of the menu bar is another, and an app that stays
    /// running behind an item that is not there is one nothing can reopen.
    var isReachable: Bool { item?.isVisible == true }

    /// Whether this item is all that is left of the app on screen.
    private(set) var isTheWholeApp = false

    /// Put the app away without ending it, leaving this item as the way back.
    ///
    /// The windows are ordered out rather than closed. Closing the last one
    /// asks whether the app should end, which is the question being answered
    /// here, and a closed `WindowGroup` window is one SwiftUI has to be talked
    /// into making again.
    func keepOnlyTheMenuBar() {
        for window in NSApp.windows where window.isVisible { window.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
        isTheWholeApp = true
    }

    /// Somebody asked for the app again — from the Dock, from Finder, or from
    /// this item's own menu.
    func comeBack() {
        guard isTheWholeApp else { return }
        isTheWholeApp = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func bringToFront() {
        if isTheWholeApp {
            comeBack()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
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
        answerVerifyLaunchIfAsked()
        // Before any window exists. Applying it once the app had finished
        // launching meant a window on a Mac set to the other appearance was
        // drawn in the system's and repainted in ours, which is a flash of the
        // wrong colours on every launch.
        MainActor.assumeIsolated { Appearance.current.apply() }
        runSmokeTestIfAsked()
        unregisterHelperIfAsked()
        // Development switches, and not in a build anybody receives.
        //
        // --reinstall-helper registers the daemon through SMAppService, which
        // is what raises "can run in the background for all users" -- a
        // question this app answers for itself with one administrator
        // password and never puts to the person twice. Shipped, it was a
        // switch that could produce a permission prompt the app is designed
        // not to need.
        #if DEVTOOLS
            reinstallHelperIfAsked()
            MainActor.assumeIsolated { checkHelperIfAsked() }
        #endif
        #if DEVTOOLS
            MainActor.assumeIsolated { EndToEnd.runIfAsked() }
            MainActor.assumeIsolated { Snapshots.runIfAsked() }
            MainActor.assumeIsolated { UpdateHarness.runIfAsked() }
        #endif
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
        .commands { LukottaCommands(model: model, updater: updater) }
        Settings {
            SettingsView()
                .environmentObject(updater)
                .environmentObject(model)
        }

    }
}

/// A small window that says the app is going, while it goes.
///
/// Ejecting takes a second or two: the drives have to be handed back and the
/// virtual machine stopped. Until that finishes the app is still on screen and
/// still answering, so from the outside a quit that was asked for looks like a
/// quit that was ignored, and the usual response is to press Quit again.
///
/// Deliberately not an NSAlert. runModal would block the very work this is
/// reporting on, and an alert with no buttons is a dialogue nobody can dismiss
/// if the eject stalls.
@MainActor
enum QuitProgress {
    private static var window: NSWindow?

    static func show(_ what: String) {
        guard window == nil else { return }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: what)
        label.translatesAutoresizingMaskIntoConstraints = false

        // The word first, the spinner under it. Side by side the spinner reads
        // as an icon belonging to the sentence; below, it is plainly the thing
        // still happening.
        label.alignment = .center

        let row = NSView()
        row.addSubview(label)
        row.addSubview(spinner)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 20),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: row.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])

        let size = NSSize(width: 240, height: 108)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = row

        // Over the window it belongs to, not wherever the screen's middle
        // happens to be. NSWindow.center puts a window a third of the way down
        // the screen with the main display's geometry, which on a second
        // display or beside an off-centre window lands nowhere in particular.
        let over = NSApp.windows.first { $0.isVisible && $0 !== panel && $0.canBecomeMain }
        let frame = over?.frame ?? NSScreen.main?.visibleFrame
        if let frame {
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        panel.level = .modalPanel
        // orderFrontRegardless, not makeKeyAndOrderFront plus activate. Quit
        // can be asked for from the menu bar while another application is in
        // front, and this panel is telling you something rather than asking:
        // pulling the whole app forward to say "Quitting" takes the screen
        // away from whatever you had turned to instead.
        panel.orderFrontRegardless()
        window = panel
    }

    // No hide(). Once this is up the app is going, and taking it down before
    // the process ends only produces a window sitting there saying nothing.
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
        // Again, harmlessly: it is set before the first window is made, and
        // this covers anything AppKit creates for itself afterwards.
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

    /// Clicking the app in the Dock, or opening it again from Finder, while it
    /// is living in the menu bar.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { MenuBarItem.shared.comeBack() }
        return true
    }

    /// A mounted drive means a microVM is still running. Quitting without
    /// ejecting would leave it behind, so ask.
    /// Whether the quit question is already on screen.
    ///
    /// runModal runs a nested event loop, so everything carries on underneath
    /// it -- including another quit. Command-Q twice, or Quit from the menu bar
    /// while the dialogue is up, and AppKit calls this again and a second alert
    /// is built on top of the first. The second one lands wherever AppKit puts
    /// an alert with no window behind it, which on more than one display is
    /// usually not the display the first is on: two dialogues, on two screens,
    /// asking the same question.
    private var isAskingAboutQuit = false

    /// Whether the app has already agreed to go and is doing the leaving.
    ///
    /// isAskingAboutQuit covers the dialogue. This covers what comes after it:
    /// between returning .terminateLater and NSApp.reply arriving, the app is
    /// still running and still answering Cmd-Q. Without this a second one
    /// starts a second finishLeaving beside the first, and the two rewrite the
    /// engine's config.toml at the same time.
    private var isLeaving = false


    /// Leave, without holding the main thread while doing it.
    ///
    /// Detaching container files and sweeping the workspaces takes a second or
    /// two of shelling out. Done on the main actor it is a spinning cursor and
    /// a window that cannot repaint, so the panel saying what is happening
    /// could never appear. Done here it is off the main thread, the panel
    /// draws, and AppKit is told when it is finished.
    @MainActor
    private func leave(after: (() -> Void)? = nil) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // Already going. The panel is up and the work is running; say yes to
        // this attempt too and let the one in flight finish and reply.
        guard !isLeaving else { return .terminateLater }
        isLeaving = true
        QuitProgress.show(String(localized: "Quitting\u{2026}"))
        let needs = model.whatLeavingNeeds()
        after?()
        Task.detached(priority: .userInitiated) {
            AppModel.finishLeaving(detaching: needs.detaching, files: needs.files)
            await MainActor.run {
                // Set here rather than on the detached task. It is read on the
                // main actor by cleanUp, and a nonisolated(unsafe) var written
                // from one thread and read on another is a race whether or not
                // it happens to hold today.
                AppModel.leftTidily = true
                // The panel is not taken down here. Saying yes is not the end:
                // AppKit still runs applicationWillTerminate and tears the app
                // down afterwards, and hiding the panel first leaves a gap
                // where the window is still on screen saying nothing. It goes
                // when the process does.
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !systemIsPoweringOff else { return .terminateNow }

        // Already asking. Bring the dialogue that exists forward rather than
        // building another, and tell AppKit this attempt is answered: the one
        // on screen is what decides.
        if isAskingAboutQuit {
            NSApp.activate(ignoringOtherApps: true)
            MainActor.assumeIsolated { NSApp.modalWindow?.makeKeyAndOrderFront(nil) }
            return .terminateCancel
        }

        // Coming straight back is not leaving. The drives are held by the
        // helper and are still there a second later, so there is nothing to
        // decide and asking only gets in the way. Without the helper they would
        // drop, and then the question is a real one.
        if AppModel.wantsRelaunch, let model, MainActor.assumeIsolated({ model.helper.isReady }) {
            return MainActor.assumeIsolated { leave() }
        }
        guard let model, MainActor.assumeIsolated({ model.hasOpenDrive }) else {
            return MainActor.assumeIsolated { leave() }
        }

        // Asked from the menu bar, by an item that says it ejects. The answer
        // this dialog exists to collect has been given.
        if MainActor.assumeIsolated({ MenuBarItem.shared.tookTheMenuBarsAnswer() }) {
            MainActor.assumeIsolated {
                QuitProgress.show(String(localized: "Quitting\u{2026}"))
                model.ejectAll { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }

        // Without the helper the virtual machine is tied to this process, so
        // leaving a drive open would drop it the moment the app quits, and macOS
        // would report the connection as interrupted. Only offer that choice
        // when the drive would actually survive.
        let survives = MainActor.assumeIsolated { model.helper.isReady }

        // Somewhere to go that is not away.
        //
        // With an item in the menu bar the app does not have to end to get out
        // of the way: the window and the Dock icon go, the item stays, and the
        // drive can be ejected from it. That also makes leaving a drive open
        // safe without the helper, since the process holding it is still here.
        //
        // Only from a full app, and only while there is an item somebody can
        // reach. Asked from the menu bar item itself there is nowhere further
        // to retreat to, and an app hidden behind an item that was switched
        // off or dragged away is one nothing can reopen.
        let retreat = MainActor.assumeIsolated {
            MenuBarItem.shared.isReachable && !MenuBarItem.shared.isTheWholeApp
        }

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
        if retreat || survives { alert.addButton(withTitle: String(localized: "Leave Open")) }
        alert.addButton(withTitle: String(localized: "Eject and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Cancel sits where AppKit puts it. NSAlert offers no way to hold it
        // apart from the two answers, and reaching into the stack it builds
        // fights a layout that is measured before the reach. Doing it properly
        // would mean building this dialog by hand, which is not worth it on the
        // path that quits the app.

        let ejectButton: NSApplication.ModalResponse =
            retreat || survives ? .alertSecondButtonReturn : .alertFirstButtonReturn
        // An app living in the menu bar has no window to raise this in front
        // of, and a modal dialogue nobody can see reads as a quit that hung.
        NSApp.activate(ignoringOtherApps: true)
        isAskingAboutQuit = true
        let answer = alert.runModal()
        isAskingAboutQuit = false

        if retreat, answer == .alertFirstButtonReturn {
            // Not a quit that was turned down: it was answered, by going to
            // the menu bar. The relaunch goes with it for the same reason a
            // cancelled quit drops it.
            AppModel.wantsRelaunch = false
            MainActor.assumeIsolated { MenuBarItem.shared.keepOnlyTheMenuBar() }
            return .terminateCancel
        }
        if survives, answer == .alertFirstButtonReturn {
            return MainActor.assumeIsolated { leave() }
        }
        let eject = answer == ejectButton
        // Turning the quit down turns the relaunch down with it, or the next
        // quit would reopen the app for no reason anyone would remember.
        if !eject { AppModel.wantsRelaunch = false }
        if eject {
            MainActor.assumeIsolated {
                // Same guard as leave(): a second Cmd-Q while the ejects are
                // running must not start them again.
                guard !isLeaving else { return }
                isLeaving = true
                QuitProgress.show(String(localized: "Quitting\u{2026}"))
                let needs = model.whatLeavingNeeds()
                model.ejectAll {
                    // The ejects are done. The rest of the leaving still has to
                    // happen, and doing it here would be on the main thread
                    // with the panel unable to redraw -- which is the beachball
                    // this panel was added to replace. It ran in
                    // applicationWillTerminate before, which is the same thread
                    // and the same stall, just later and less visible.
                    Task.detached(priority: .userInitiated) {
                        AppModel.finishLeaving(detaching: needs.detaching, files: needs.files)
                        await MainActor.run {
                            AppModel.leftTidily = true
                            NSApp.reply(toApplicationShouldTerminate: true)
                        }
                    }
                }
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

/// The app's own menus.
///
/// A type of its own rather than a `.commands` block written inline. Inline it
/// was attached to the Settings scene, which is not where an application's
/// menus belong, and the whole scene body grew large enough that the type
/// checker gave up on it. Both of those are the sort of thing that shows up as
/// a menu bar behaving strangely rather than as an error.
struct LukottaCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some Commands {
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
