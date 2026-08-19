import SwiftUI
import AppKit

@main
struct BitLockerMounterApp: App {
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
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Remove this session's private workspace so the app leaves nothing behind.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanUp() }
    }
}
