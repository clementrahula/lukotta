// Measures the Lukotta mark from the source artwork: bounding box, colours and
// the geometry of the cut. Used to calibrate scripts/make-icon.swift.
import AppKit

let src = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: src),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else { fatalError("cannot read \(src)") }

let w = rep.pixelsWide, h = rep.pixelsHigh
func lum(_ x: Int, _ y: Int) -> CGFloat {
    guard let c = rep.colorAt(x: x, y: y) else { return 1 }
    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
}
let darkT: CGFloat = 0.45

// Row bands containing dark pixels: the mark is the topmost band, the wordmark
// sits below it with a clear gap.
var bands: [(Int, Int)] = []
var runStart = -1
for y in 0..<h {
    var dark = 0
    for x in stride(from: 0, to: w, by: 2) where lum(x, y) < darkT { dark += 1 }
    let has = dark > 2
    if has && runStart < 0 { runStart = y }
    if !has && runStart >= 0 { bands.append((runStart, y - 1)); runStart = -1 }
}
if runStart >= 0 { bands.append((runStart, h - 1)) }
print("dark row bands (top-origin): \(bands.map { "\($0.0)-\($0.1)" }.joined(separator: ", "))")

guard let mark = bands.first else { fatalError("no mark found") }
var minX = w, maxX = 0
for y in mark.0...mark.1 {
    for x in 0..<w where lum(x, y) < darkT {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
    }
}
let mw = maxX - minX + 1, mh = mark.1 - mark.0 + 1
print("mark bbox: x=\(minX) y=\(mark.0) w=\(mw) h=\(mh)  (aspect \(String(format: "%.3f", Double(mw)/Double(mh))))")

// Colours: charcoal from the mark's interior, cream from a corner of the canvas.
if let dark = rep.colorAt(x: minX + mw / 5, y: mark.0 + mh / 2),
   let pale = rep.colorAt(x: 4, y: 4) {
    func hex(_ c: NSColor) -> String {
        let r = c.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X  rgb(%.3f, %.3f, %.3f)",
                      Int(r.redComponent*255), Int(r.greenComponent*255), Int(r.blueComponent*255),
                      r.redComponent, r.greenComponent, r.blueComponent)
    }
    print("charcoal: \(hex(dark))")
    print("cream:    \(hex(pale))")
}

// Corner radius: on the top edge, find how far in the dark starts, scanning down.
var inset = -1
for dy in 0..<(mh/2) {
    let y = mark.0 + dy
    var firstDark = -1
    for x in minX...maxX where lum(x, y) < darkT { firstDark = x; break }
    if firstDark >= 0 && dy == 0 { inset = firstDark - minX }
    if firstDark == minX { print("corner radius ≈ \(dy) px = \(String(format: "%.3f", Double(dy)/Double(mw))) of width"); break }
}
_ = inset

// The cut: for sampled rows, find pale pixels inside the mark.
print("cut trace (fraction down, fraction across):")
for f in stride(from: 0.05, through: 0.95, by: 0.1) {
    let y = mark.0 + Int(Double(mh) * f)
    var runs: [(Int, Int)] = []
    var s = -1
    for x in minX...maxX {
        let pale = lum(x, y) >= darkT
        if pale && s < 0 { s = x }
        if !pale && s >= 0 { runs.append((s, x-1)); s = -1 }
    }
    if s >= 0 { runs.append((s, maxX)) }
    let inner = runs.filter { $0.0 > minX + mw/20 && $0.1 < maxX - mw/20 }
    if let c = inner.first {
        let mid = Double(c.0 + c.1) / 2.0
        print(String(format: "  y=%.2f  centre=%.3f  width=%.4f",
                     f, (mid - Double(minX)) / Double(mw), Double(c.1 - c.0 + 1) / Double(mw)))
    } else {
        print(String(format: "  y=%.2f  (no cut)", f))
    }
}
