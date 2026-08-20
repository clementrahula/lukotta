// Renders the Lukotta app icon and writes an .icns.
// Drawn programmatically so the icon is reproducible from source.
import AppKit
import CoreGraphics

let size: CGFloat = 1024

func drawIcon(into ctx: CGContext) {
    // The Lukotta mark: a charcoal squircle split by a pale cut that turns a
    // corner, so the negative space reads as an L and as an opening lock.
    let margin: CGFloat = size * 0.085
    let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.275

    let charcoal = CGColor(red: 0.204, green: 0.231, blue: 0.271, alpha: 1)   // #343B45
    let cream    = CGColor(red: 0.965, green: 0.953, blue: 0.929, alpha: 1)   // #F6F3ED

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    ctx.setFillColor(charcoal)
    ctx.fill(rect)

    // Measurements are taken top-down from the logo, then flipped: CGContext
    // here is y-up, so a fraction f down the mark sits at maxY - f * height.
    func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + fx * rect.width, y: rect.maxY - fy * rect.height)
    }

    // The cut runs off both edges so it slices cleanly through the clip.
    let cut = CGMutablePath()
    cut.move(to: p(0.450, -0.06))
    cut.addLine(to: p(0.516, 0.700))
    cut.addLine(to: p(1.06, 0.788))

    ctx.setStrokeColor(cream)
    ctx.setLineWidth(rect.width * 0.052)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(10)
    ctx.setLineCap(.butt)
    ctx.addPath(cut)
    ctx.strokePath()

    ctx.restoreGState()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Lukotta-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for px in sizes {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
    ctx.setAllowsAntialiasing(true)
    drawIcon(into: ctx)
    guard let img = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }

    // iconutil expects icon_<pt>x<pt>[@2x].png
    for (name, expect) in [("icon_\(px)x\(px).png", px), ("icon_\(px/2)x\(px/2)@2x.png", px)] {
        guard expect == px else { continue }
        if name.contains("@2x") && px < 32 { continue }
        try? png.write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed (\(p.terminationStatus))")
