import AppKit
import SwiftUI

/// A pop-up button that fills the row it is given.
///
/// SwiftUI's Picker keeps its control at the width of its longest choice, and
/// its Menu expands the frame but centres the label inside it, so neither fills
/// a row with the title against the left edge. NSPopUpButton does that by
/// itself — it is the control the rest of macOS uses for this — so it is used
/// directly rather than argued with.
struct PopUpRow: NSViewRepresentable {
    /// A value of nil marks a separator rather than a choice.
    let choices: [(value: String?, title: String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.pick(_:))
        // Stretch rather than sit at its natural width, and do not push the row
        // wider than it is.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()
        for choice in choices {
            guard let value = choice.value else {
                button.menu?.addItem(.separator())
                continue
            }
            button.addItem(withTitle: choice.title)
            button.lastItem?.representedObject = value
        }
        let match = button.itemArray.firstIndex { $0.representedObject as? String == selection }
        button.selectItem(at: match ?? 0)
    }

    final class Coordinator: NSObject {
        var parent: PopUpRow
        init(_ parent: PopUpRow) { self.parent = parent }

        // An action sent by a control, so it arrives on the main thread. The
        // SDK does not say so, and the older one this is built against on CI
        // says the opposite.
        @MainActor
        @objc func pick(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = value
        }
    }
}
