// Draws the placeholder icon and mark that unbranded builds carry.
//
// Deliberately dull: a grey rounded square with a keyhole. It has to be
// obviously a placeholder, and it must not resemble the Lukotta mark, which is
// a trademark and is not licensed under the GPL. Anyone shipping a fork should
// replace this with their own artwork rather than keep it.
//
//   swift scripts/make-placeholder-art.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// One placeholder, drawn at whatever size is asked for.
///
/// Every measurement is a fraction of the canvas, so each size is drawn rather
/// than resampled from a larger one and nothing ends up soft.
func draw(size: Int, inset: CGFloat) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(size)px context") }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let box = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * inset, dy: s * inset)
    let body = CGPath(
        roundedRect: box, cornerWidth: box.width * 0.22, cornerHeight: box.width * 0.22,
        transform: nil)
    ctx.addPath(body)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1))
    ctx.fillPath()

    // A keyhole, cut clean out of the body so the placeholder reads at 16px.
    ctx.setBlendMode(.clear)
    let r = box.width * 0.15
    let centre = CGPoint(x: box.midX, y: box.midY + box.height * 0.08)
    ctx.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    ctx.fillPath()

    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: centre.x - r * 0.45, y: centre.y))
    stem.addLine(to: CGPoint(x: centre.x + r * 0.45, y: centre.y))
    stem.addLine(to: CGPoint(x: centre.x + r * 0.80, y: box.minY + box.height * 0.20))
    stem.addLine(to: CGPoint(x: centre.x - r * 0.80, y: box.minY + box.height * 0.20))
    stem.closeSubpath()
    ctx.addPath(stem)
    ctx.fillPath()

    guard let image = ctx.makeImage() else { fatalError("could not render \(size)px") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)px")
    }
    return png
}

func write(_ data: Data, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    print("  \(path)  \(data.count) bytes")
}

// The app icon. Inset the way macOS icons sit in their canvas.
let icon = "\(out)/AppIconUnbranded.appiconset"
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = points * scale
        let suffix = scale == 1 ? "@1x" : "@2x"
        write(draw(size: px, inset: 0.09), "\(icon)/icon_\(points)x\(points)\(suffix).png")
    }
}

// The mark shown in the app itself, at the size the interface asks for.
let mark = "\(out)/MarkUnbranded.imageset"
for scale in [1, 2, 3] {
    write(draw(size: 26 * scale, inset: 0.02), "\(mark)/placeholder-\(scale)x.png")
}
