import AppKit
import LukottaCore
import SwiftUI

@main
struct LukottaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
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
        MenuBarExtra(
            isInserted: Binding(
                get: { !model.openMounts.isEmpty },
                set: { _ in })
        ) {
            ForEach(Array(model.openMounts.values.sorted()), id: \.self) { path in
                Button("Eject \((path as NSString).lastPathComponent)") {
                    model.eject(path)
                }
            }
            Divider()
            Button("Open Lukotta") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit Lukotta") { NSApp.terminate(nil) }
        } label: {
            // Drawn as a template symbol rather than the app's own mark: the
            // mark's diagonal cut is under a pixel wide at this size, so it
            // would read as a plain filled square. A template glyph is also
            // what inverts by itself between a light and a dark menu bar.
            Image(systemName: "lock.open")
                .font(.system(size: 14, weight: .medium))
                .accessibilityLabel("Lukotta — a drive is open")
        }
        .menuBarExtraStyle(.menu)

        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .help) {
                Button("Lukotta Help") { model.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Report an Issue…") { model.showReport = true }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// A mounted drive means a microVM is still running. Quitting without
    /// ejecting would leave it behind, so ask.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let model, MainActor.assumeIsolated({ model.hasOpenDrive }) else {
            return .terminateNow
        }

        // Without the helper the virtual machine is tied to this process, so
        // leaving a drive open would drop it the moment the app quits, and macOS
        // would report the connection as interrupted. Only offer that choice
        // when the drive would actually survive.
        let survives = MainActor.assumeIsolated { model.helper.isReady }

        let alert = NSAlert()
        alert.messageText = "A drive is still open"
        alert.informativeText =
            survives
            ? "Ejecting keeps your files safe. Leaving it open keeps the drive available in Finder."
            : "Ejecting keeps your files safe. Quitting without ejecting will disconnect the drive."
        alert.addButton(withTitle: "Eject and Quit")
        if survives { alert.addButton(withTitle: "Leave Open") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            MainActor.assumeIsolated {
                model.ejectAll { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return survives ? .terminateNow : .terminateCancel
        default:
            return .terminateCancel
        }
    }

    /// Remove this session's private workspace so the app leaves nothing behind.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanUp() }
    }
}
