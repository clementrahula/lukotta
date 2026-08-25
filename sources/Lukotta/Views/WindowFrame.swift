// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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
/// Whether the app is moving the window itself at this moment.
///
/// A frame is remembered when the window moves or resizes, which is how
/// somebody's own choice of size survives a quit. The app also sizes the window
/// -- when a screen wants less width than the one before it -- and that arrived
/// through the same notification, was written down as though it had been
/// dragged, and from then on the app never adjusted the width again: it had
/// been told, by itself, to keep its hands off.
@MainActor
enum WindowGeometry {
    static var isAdjusting = false
}

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

    /// Every method here touches a window, and every one of them is reached
    /// from the main thread: a view discovering its window, and notifications
    /// asked for on the main queue. The SDK Lukotta is built against does not
    /// insist, and an older one does.
    @MainActor
    final class Coordinator {
        private let key: String
        private weak var window: NSWindow?

        init(key: String) { self.key = key }

        func adopt(_ window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            settle(window)
            // Not shown until it is where it belongs.
            //
            // SwiftUI puts the window up at its own size and position, and the
            // remembered frame is applied a moment later -- which is a window
            // that appears in one place, at one size, and jumps to another
            // while somebody is looking at it. On a Mac with two displays the
            // jump crosses displays, so the app appears to open on the wrong
            // one. Drawn transparent until the frame is settled instead.
            window.alphaValue = 0
            restore(into: window)

            // And again, once SwiftUI has had its turn.
            //
            // Setting the frame here works and is then undone: SwiftUI sizes
            // and places the window itself immediately afterwards — three
            // frames within the same millisecond, ending at the content's
            // minimum size in a cascaded position. Restoring after that is what
            // makes it stick.
            //
            // Nothing is recorded until then either. The old code started
            // watching straight away and dutifully saved each of those three,
            // so every launch overwrote the remembered frame with wherever
            // SwiftUI had just put the window — which is why it looked as
            // though nothing was being remembered at all.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.restore(into: window)
                    self.watch(window)
                    window.alphaValue = 1
                }
            }
            // Whatever happens above, the window becomes visible. A window that
            // stayed transparent because something went wrong is an app that
            // does nothing when opened, which is worse than any jump.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
                window?.alphaValue = 1
            }
        }

        /// What this window will not do.
        ///
        /// There is one window, it holds a column of text and a row of buttons,
        /// and none of that is better for being the size of a display. Full
        /// screen is off, and the green button with it, which is how macOS's
        /// own settings window behaves. Dragging an edge still works for
        /// anyone who wants it larger.
        ///
        /// Here because this is where the window is already in hand. A second
        /// observer for one line of setup would be a second thing to keep in
        /// step with the first.
        private func settle(_ window: NSWindow) {
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }

        /// Closing counts too: a window the user never dragged still has a size
        /// worth keeping, and quitting is when most people leave.
        private func watch(_ window: NSWindow) {
            for name in [
                NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                NSWindow.willCloseNotification,
            ] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                }
            }
        }

        private func restore(into window: NSWindow) {
            // A snapshot window is given the size the scene is meant to be
            // drawn at. Restoring a remembered frame over it made every
            // picture the size of whatever this machine last left the app at,
            // captured into a bitmap of the size that was asked for -- so the
            // small ones were a crop of the large ones rather than a layout at
            // the smallest size the window goes to, and the baselines only
            // matched on the machine that recorded them.
            guard !CommandLine.arguments.contains("--snapshots") else { return }
            guard let saved = UserDefaults.standard.string(forKey: key) else {
                // Nothing remembered, which is every first launch. Centred on
                // the display the pointer is on -- where the person is looking
                // -- rather than wherever the window server cascades it, which
                // on a Mac with two displays is as likely to be the other one.
                centreOnTheActiveScreen(window)
                return
            }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }

            // A frame saved on a monitor that is no longer attached would put
            // the window somewhere the user cannot reach it.
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            guard visible else { return }

            window.setFrame(frame, display: true)
        }

        private func centreOnTheActiveScreen(_ window: NSWindow) {
            let pointer = NSEvent.mouseLocation
            let screen =
                NSScreen.screens.first { $0.frame.contains(pointer) }
                ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            var frame = window.frame
            frame.origin.x = visible.midX - frame.width / 2
            // A shade above centre, which is where a window looks placed rather
            // than dropped: the same proportion AppKit uses for its own.
            frame.origin.y = visible.midY - frame.height / 2 + visible.height * 0.08
            window.setFrame(frame, display: false)
        }

        private func save() {
            // Not what the app just did to the window; only what was done to it.
            guard !WindowGeometry.isAdjusting else { return }
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

    /// Narrow the window to what this screen actually needs.
    ///
    /// Only the permission screen is wide: it carries a picture of the pane it
    /// describes. Everything after it is a list of drives and a row of buttons,
    /// and leaving the window at the width the picture wanted made the list
    /// look like a table with a column missing.
    ///
    /// Only ever on a window nobody has sized themselves. Somebody who has
    /// dragged an edge has said what they want, and no screen overrides that.
    func widthWanted(_ width: CGFloat, key: String) -> some View {
        background(WindowWidth(width: width, key: key).frame(width: 0, height: 0))
    }
}

private struct WindowWidth: NSViewRepresentable {
    let width: CGFloat
    let key: String

    func makeNSView(context: Context) -> NSView {
        let view = RememberFrame.WindowWatcher()
        view.onWindow = { window in
            MainActor.assumeIsolated { context.coordinator.apply(width, to: window, key: key) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        MainActor.assumeIsolated { context.coordinator.apply(width, to: window, key: key) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var applied: CGFloat?

        func apply(_ width: CGFloat, to window: NSWindow, key: String) {
            guard applied != width else { return }
            applied = width
            // A remembered frame is somebody's own decision about how big this
            // window should be.
            guard UserDefaults.standard.string(forKey: key) == nil else { return }
            guard abs(window.frame.width - width) > 1 else { return }
            var frame = window.frame
            // Grown or shrunk about the middle, so the window does not walk
            // across the display each time a screen changes.
            frame.origin.x += (frame.width - width) / 2
            frame.size.width = width
            WindowGeometry.isAdjusting = true
            window.setFrame(frame, display: true, animate: window.isVisible)
            // The notifications arrive after this returns, so the flag is
            // cleared once they have been and gone.
            DispatchQueue.main.async { WindowGeometry.isAdjusting = false }
        }
    }
}
