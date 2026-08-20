import AppKit
import LukottaCore
import SwiftUI

@main
struct LukottaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    model.start()
                }
        }
        .windowResizability(.contentMinSize)
        // Present only while something is open, so it does not clutter the menu
        // bar for a tool used occasionally.
        MenuBarExtra(
            "Lukotta", systemImage: "lock.open.fill",
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
        }

        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Lukotta Help") { model.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
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

        let alert = NSAlert()
        alert.messageText = "A drive is still open"
        alert.informativeText =
            "Ejecting keeps your files safe and shuts down the background helper. "
            + "Leaving it open keeps the drive available, but the helper keeps running."
        alert.addButton(withTitle: "Eject and Quit")
        alert.addButton(withTitle: "Leave Open")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            MainActor.assumeIsolated {
                model.ejectAll { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Remove this session's private workspace so the app leaves nothing behind.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanUp() }
    }
}
