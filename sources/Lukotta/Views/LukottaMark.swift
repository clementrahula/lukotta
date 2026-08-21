import AppKit
import SwiftUI

/// The Lukotta mark, from the artwork rather than a copy of it.
///
/// This was a shape drawn from measurements taken off the logo, because the
/// source is a 448 px raster and an icon needs more. That was a reasonable
/// trade for the icon and a poor one here: at header size the reconstruction
/// read as two overlapping squares rather than the L the mark actually makes.
///
/// The bundled asset carries only an alpha channel, so it takes the foreground
/// colour and reads against either appearance — the same adaptivity the drawn
/// version had, with the real geometry.
struct LukottaMark: View {
    var body: some View {
        Image(nsImage: Self.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }

    private static let template: NSImage = {
        guard let url = Bundle.main.url(forResource: "LukottaMark", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return NSImage(size: .zero) }
        // A template takes the foreground colour, which is what lets one asset
        // serve a light window and a dark one.
        image.isTemplate = true
        return image
    }()
}
