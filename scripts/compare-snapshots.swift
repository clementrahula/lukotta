// Compare two directories of PNGs and say which ones changed.
//
//   swift scripts/compare-snapshots.swift <baseline> <candidate> [tolerance]
//
// Exact equality would fail on every macOS point release: text is antialiased,
// and a hinting change moves a handful of subpixels without moving anything a
// person would notice. So a picture passes while fewer than `tolerance` of its
// pixels differ, and the default is a tenth of a percent — far below a shifted
// control, far above a re-rendered glyph.
//
// Exits 0 when everything matches, 1 when anything does not.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: compare-snapshots.swift <baseline> <candidate> [tolerance]\n".utf8))
    exit(2)
}
let baseline = URL(fileURLWithPath: args[1])
let candidate = URL(fileURLWithPath: args[2])
let tolerance = args.count > 3 ? Double(args[3]) ?? 0.001 : 0.001

func pngs(in directory: URL) -> [String] {
    let names =
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".png") }.sorted()
}

/// The fraction of pixels that differ, or nil when the two cannot be compared.
func difference(_ a: URL, _ b: URL) -> Double? {
    guard
        let left = NSImage(contentsOf: a)?.representations.first as? NSBitmapImageRep,
        let right = NSImage(contentsOf: b)?.representations.first as? NSBitmapImageRep,
        left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh,
        let lhs = left.bitmapData, let rhs = right.bitmapData
    else { return nil }

    let width = left.pixelsWide, height = left.pixelsHigh
    let lhsRow = left.bytesPerRow, rhsRow = right.bytesPerRow
    let lhsPixel = left.bitsPerPixel / 8, rhsPixel = right.bitsPerPixel / 8
    var differing = 0
    for y in 0..<height {
        for x in 0..<width {
            let l = lhs + y * lhsRow + x * lhsPixel
            let r = rhs + y * rhsRow + x * rhsPixel
            // A per-channel threshold as well: a single step of difference in
            // one channel is a rounding artefact, not a change.
            for channel in 0..<3 where abs(Int(l[channel]) - Int(r[channel])) > 2 {
                differing += 1
                break
            }
        }
    }
    return Double(differing) / Double(width * height)
}

let expected = pngs(in: baseline)
let actual = Set(pngs(in: candidate))
var failures: [String] = []

if expected.isEmpty {
    FileHandle.standardError.write(Data("no baselines in \(baseline.path)\n".utf8))
    exit(2)
}

for name in expected {
    guard actual.contains(name) else {
        failures.append("\(name): missing — the scene is gone or was renamed")
        continue
    }
    guard
        let fraction = difference(
            baseline.appendingPathComponent(name), candidate.appendingPathComponent(name))
    else {
        failures.append("\(name): a different size, or unreadable")
        continue
    }
    if fraction > tolerance {
        failures.append(
            String(format: "%@: %.2f%% of pixels changed", name, fraction * 100))
    }
}
for name in actual.subtracting(expected).sorted() {
    failures.append("\(name): new — record it if the scene is meant to be there")
}

if failures.isEmpty {
    print("  \(expected.count) snapshots match")
    exit(0)
}
print("  \(failures.count) of \(expected.count) snapshots differ:")
for line in failures { print("    \(line)") }
exit(1)
