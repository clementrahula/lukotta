import AppKit
import SwiftUI

/// Remember where the window was, under a name that does not move.
///
/// SwiftUI saves a window's frame under a key built from the type of its
/// content: `NSWindow Frame SwiftUI.ModifiedContent<...ContentView...>`. Adding
/// a modifier changes that type, which changes the key, and the window silently
/// forgets its size and position.
///
/// Renaming the window's own autosave does not work, because SwiftUI sets its
/// name after the view appears and takes it back. So the frame is saved and
/// restored here instead, under a key we choose.
struct RememberFrame: NSViewRepresentable {
    let key: String

    func makeCoordinator() -> Coordinator { Coordinator(key: key) }

    func makeNSView(context: Context) -> NSView {
        // A view has no window while it is being made, and asking on the next
        // pass of the run loop is a guess that was wrong here. AppKit says when
        // it happens.
        let view = WindowWatcher()
        view.onWindow = { [coordinator = context.coordinator] window in
            coordinator.adopt(window)
        }
        return view
    }

    /// An invisible view whose only job is to notice the window it lands in.
    final class WindowWatcher: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow?(window)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private let key: String
        private weak var window: NSWindow?

        init(key: String) { self.key = key }

        func adopt(_ window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            restore(into: window)

            // Closing counts too: a window the user never dragged still has a
            // size worth keeping, and quitting is when most people leave.
            for name in [
                NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                NSWindow.willCloseNotification,
            ] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.save()
                }
            }
        }

        private func restore(into window: NSWindow) {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }

            // A frame saved on a monitor that is no longer attached would put
            // the window somewhere the user cannot reach it.
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            guard visible else { return }

            window.setFrame(frame, display: true)
        }

        private func save() {
            guard let window else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
        }
    }
}

extension View {
    /// Keep this window's size and position across launches.
    func remembersFrame(as key: String) -> some View {
        background(RememberFrame(key: key).frame(width: 0, height: 0))
    }
}
