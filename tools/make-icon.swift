// Renders the FULocker app icon and writes an .icns.
// Drawn programmatically so the icon is reproducible from source.
import AppKit
import CoreGraphics

let size: CGFloat = 1024

func drawIcon(into ctx: CGContext) {
    // macOS icons sit on a rounded-rect "squircle" with margin.
    let margin: CGFloat = size * 0.09
    let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.2237   // Big Sur corner ratio

    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Deep indigo -> violet, reading as "secure" without being a cliché padlock-on-grey.
    let colors = [
        CGColor(red: 0.24, green: 0.20, blue: 0.62, alpha: 1),
        CGColor(red: 0.42, green: 0.24, blue: 0.78, alpha: 1),
        CGColor(red: 0.60, green: 0.31, blue: 0.86, alpha: 1),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }

    // Soft highlight across the top for depth.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.fillEllipse(in: CGRect(x: rect.minX - rect.width * 0.2,
                               y: rect.midY + rect.height * 0.12,
                               width: rect.width * 1.4, height: rect.height * 0.85))
    ctx.restoreGState()

    // Subtle inner edge.
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(size * 0.006)
    ctx.strokePath()

    // --- Drive body -------------------------------------------------------
    let dW = rect.width * 0.56
    let dH = rect.height * 0.34
    let drive = CGRect(x: rect.midX - dW / 2, y: rect.minY + rect.height * 0.17,
                       width: dW, height: dH)
    let drivePath = CGPath(roundedRect: drive, cornerWidth: dH * 0.22,
                           cornerHeight: dH * 0.22, transform: nil)
    ctx.addPath(drivePath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()

    // Activity light on the drive.
    let lamp = CGRect(x: drive.minX + drive.width * 0.12,
                      y: drive.minY + drive.height * 0.36,
                      width: drive.height * 0.16, height: drive.height * 0.16)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.24, blue: 0.78, alpha: 1))
    ctx.fillEllipse(in: lamp)

    // --- Shackle rising out of the drive ----------------------------------
    let shackleW = drive.width * 0.42
    let shackleCenter = CGPoint(x: rect.midX, y: drive.maxY + rect.height * 0.10)
    let lineW = size * 0.052
    ctx.setLineWidth(lineW)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    let arc = CGMutablePath()
    arc.addArc(center: shackleCenter, radius: shackleW / 2,
               startAngle: .pi, endAngle: 0, clockwise: false)
    arc.move(to: CGPoint(x: shackleCenter.x - shackleW / 2, y: shackleCenter.y))
    arc.addLine(to: CGPoint(x: shackleCenter.x - shackleW / 2, y: drive.maxY - lineW * 0.1))
    arc.move(to: CGPoint(x: shackleCenter.x + shackleW / 2, y: shackleCenter.y))
    arc.addLine(to: CGPoint(x: shackleCenter.x + shackleW / 2, y: shackleCenter.y - rect.height * 0.055))
    ctx.addPath(arc)
    ctx.strokePath()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("FULocker-\(UUID().uuidString).iconset")
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
