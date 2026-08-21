import AppKit
import LukottaCore
import SwiftUI

/// Render every screen to a PNG, so a layout that breaks is caught here rather
/// than on someone's desk.
///
/// Several regressions in this project reached the screen because nothing
/// checked what was drawn: a window that forgot its frame, an alert that
/// collapsed to a sliver, a dropdown that would not fill its row. All of them
/// were visible in a picture and invisible to every other kind of test.
///
/// Runs inside the app, behind `--snapshots`, because the views live in the
/// application target and nothing else can see them. `scripts/snapshots.sh`
/// drives it and does the comparing.
enum Snapshots {

    /// The states worth a picture, with the interface put into each by hand.
    ///
    /// Every one of them is a screen someone can arrive at. States that differ
    /// only in wording are left out — this is a check on layout.
    @MainActor
    static func scenes() -> [(name: String, model: AppModel)] {
        let drive = Drive(
            id: "disk4s1", devicePath: "/dev/disk4s1", name: "Elements",
            sizeBytes: 500_072_185_856, connection: "USB · \(appString("External"))",
            kind: .microsoft, uuid: "SNAPSHOT-0000-0000-0000-000000000001")
        let linux = Drive(
            id: "disk5s2", devicePath: "/dev/disk5s2", name: "fedora",
            sizeBytes: 1_000_204_886_016, connection: "USB · \(appString("External"))",
            kind: .linux, uuid: "SNAPSHOT-0000-0000-0000-000000000002")

        func model(_ configure: (AppModel) -> Void) -> AppModel {
            let m = AppModel()
            configure(m)
            return m
        }

        return [
            ("permission", model { $0.phase = .needsPermission }),
            ("scanning", model { $0.phase = .scanning }),
            ("empty", model { $0.phase = .chooseDrive }),
            (
                "drives",
                model {
                    $0.drives = [drive, linux]
                    $0.phase = .chooseDrive
                }
            ),
            // A drive open, with the free space and volume count the list shows
            // once it is: the row is at its widest here.
            (
                "drives-open",
                model {
                    $0.drives = [drive, linux]
                    $0.openMounts = ["/dev/disk4s1": "/Volumes/Elements"]
                    $0.space = [
                        "/Volumes/Elements": VolumeSpace(
                            free: 61_000_000_000, total: 500_000_000_000)
                    ]
                    $0.volumeCount = ["/Volumes/Elements": 3]
                    $0.phase = .chooseDrive
                }
            ),
            // Mid-eject: the row says what it is doing and cannot be pressed
            // again while it does it.
            (
                "drives-ejecting",
                model {
                    $0.drives = [drive, linux]
                    $0.openMounts = ["/dev/disk4s1": "/Volumes/Elements"]
                    $0.ejectingPath = "/Volumes/Elements"
                    $0.phase = .chooseDrive
                }
            ),
            // A container file in the list beside a physical drive: the same
            // row, saying where it lives in Disk Utility's words.
            (
                "drives-image",
                model {
                    $0.drives = [
                        drive,
                        Drive(
                            id: "disk6", devicePath: "/dev/disk6", name: "backup",
                            sizeBytes: 8_589_934_592,
                            connection: appString("Disk Image"),
                            kind: .linux, uuid: "/Users/someone/backup.img"),
                    ]
                    $0.phase = .chooseDrive
                }
            ),
            // A file that held nothing openable.
            (
                "drives-image-refused",
                model {
                    $0.drives = [drive]
                    $0.imageProblem = appString(
                        "There is nothing in “notes.txt” that \(appName) can open. It holds no BitLocker, LUKS, NTFS or Linux volume."
                    )
                    $0.phase = .chooseDrive
                }
            ),
            ("unlock", model { $0.phase = .unlock(drive) }),
            (
                "unlock-problem",
                model {
                    $0.phase = .unlock(drive)
                    $0.credentialProblem = appString(
                        "That password or recovery key did not unlock this drive.")
                }
            ),
            ("unlock-linux", model { $0.phase = .unlock(linux) }),
            // A drive that turned out not to be encrypted, said before anyone
            // goes looking for a password.
            (
                "unlock-unencrypted",
                model {
                    $0.phase = .unlock(drive)
                    $0.chosenFormat = .ntfs
                }
            ),
            (
                "working",
                model {
                    $0.phase = .working(drive)
                    $0.statusLines = ["Attaching the drive", "Unlocking the volume"]
                }
            ),
            ("mounted", model { $0.phase = .mounted(drive, "/Volumes/Elements") }),
            (
                "failed",
                model {
                    // Through Diagnosis, so the sentence on screen is the
                    // one the app would really produce.
                    let transcript = "engine: failed to open encrypted device /dev/disk4s1"
                    $0.phase = .failed(
                        drive, Diagnosis.summarise(transcript, fallback: ""), transcript)
                }
            ),
        ]
    }

    /// Window sizes to draw each scene at.
    ///
    /// The size the window opens at, and the smallest it can be dragged to. A
    /// layout that survives both ends survives what is in between, and the
    /// small one is where text runs out of room.
    ///
    /// There is deliberately no text-size axis. `dynamicTypeSize` changes
    /// nothing on macOS — every scene rendered at `.accessibility3` came out
    /// byte-identical to the same scene at `.large` — so an axis for it would
    /// have doubled the baselines while checking nothing. Text that needs more
    /// room than English is covered by rendering in another language instead,
    /// which is the same failure and one that actually happens here.
    static let geometries: [(name: String, size: NSSize)] = [
        ("ideal", NSSize(width: 640, height: 620)),
        ("min", NSSize(width: 580, height: 560)),
    ]

    @MainActor
    static func runIfAsked() {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshots") else { return }
        let directory = URL(
            fileURLWithPath: CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : "snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Both appearances, because the palette is defined twice and only one
        // of them is ever being looked at.
        let appearances = [
            ("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua)),
        ]

        var written = 0
        for (schemeName, appearance) in appearances {
            for (geometryName, size) in geometries {
                for (sceneName, model) in scenes() {
                    let view = ContentView().environmentObject(model)
                    let name = "\(sceneName)-\(geometryName)-\(schemeName).png"
                    guard let png = render(view, appearance: appearance, size: size) else {
                        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                        exit(1)
                    }
                    try? png.write(to: directory.appendingPathComponent(name))
                    written += 1
                }
            }
        }
        print("wrote \(written) snapshots to \(directory.path)")
        exit(0)
    }

    /// Draw a view the way AppKit would, and hand back a PNG.
    ///
    /// Through a real window rather than `ImageRenderer`. The renderer draws
    /// SwiftUI on its own and comes back with the inside of a `ScrollView`
    /// empty — which is where the drive list lives, so the one screen most
    /// worth checking would be the one screen not checked. Hosting it in an
    /// off-screen window draws what the app draws, scroll views included.
    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance?, size: NSSize) -> Data?
    {
        let frame = NSRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        if let appearance { window.appearance = appearance }
        // Far enough away that nobody sees it. A window that is never brought
        // on screen at all does not lay out.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // SwiftUI settles over a turn of the run loop; capturing before it has
        // gives half-drawn text and missing rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // The bitmap is made at one pixel to the point rather than taken from
        // the display, so a baseline recorded on a Retina Mac matches one
        // recorded anywhere else.
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(frame.width), pixelsHigh: Int(frame.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }
}
