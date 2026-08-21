import SwiftUI

/// The Lukotta mark.
///
/// An image in an asset catalog: the artwork at 1x, 2x and 3x, with a light and
/// a dark version of each. macOS picks the one matching the screen and the
/// appearance, so nothing here scales or tints anything.
struct LukottaMark: View {
    var body: some View {
        Image("LukottaMark")
            .accessibilityHidden(true)
    }
}
