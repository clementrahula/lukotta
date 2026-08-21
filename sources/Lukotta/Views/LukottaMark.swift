import SwiftUI

/// The Lukotta mark, drawn to adapt to the interface.
///
/// The app icon itself is charcoal on cream, which is right in the Dock and
/// invisible in a dark window header — a dark square on a dark background. This
/// draws the same geometry monochrome, so it takes the foreground colour and
/// reads at any size against either appearance.
///
/// Proportions are the measured ones from `scripts/analyse-logo.swift`:
/// corner radius 0.174 of width, the cut running 0.332 to 0.492 across as it
/// descends to 0.72 down, then out to the right edge at 0.79, stroked at 0.053.
struct LukottaMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let rect = CGRect(origin: .zero, size: size)

            context.drawLayer { layer in
                let body = Path(
                    roundedRect: rect,
                    cornerRadius: w * 0.174,
                    style: .continuous)
                layer.fill(body, with: .color(.primary))

                var cut = Path()
                cut.move(to: CGPoint(x: w * 0.332, y: -h * 0.06))
                cut.addLine(to: CGPoint(x: w * 0.492, y: h * 0.72))
                cut.addLine(to: CGPoint(x: w * 1.06, y: h * 0.79))

                // Punch the cut out rather than painting over it, so the mark
                // works on any background.
                layer.blendMode = .destinationOut
                layer.stroke(
                    cut,
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: w * 0.053, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
