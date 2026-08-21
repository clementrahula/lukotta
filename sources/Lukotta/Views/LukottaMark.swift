import AppKit
import SwiftUI

/// The Lukotta mark, from the artwork rather than a copy of it.
///
/// This was a shape drawn from measurements taken off the logo, because the
/// source is a 448 px raster and an icon needs more. That was a reasonable
/// trade for the icon and a poor one here: at header size the reconstruction
/// read as two overlapping squares rather than the L the mark actually makes.
///
/// Two renderings rather than one tinted template. A template is drawn through
/// a mask, which is one more resampling step than the artwork needs, and the
/// mark has a colour of its own in each appearance: charcoal on light, cream on
/// dark.
struct LukottaMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: scheme == .dark ? Self.dark : Self.light)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    private static let light = load("LukottaMarkLight")
    private static let dark = load("LukottaMarkDark")

    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return NSImage(size: .zero) }
        return image
    }
}
