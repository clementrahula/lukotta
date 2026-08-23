// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

/// Render every screen to a PNG, so a layout that breaks is caught here rather
/// than on someone's desk.
///
/// Several regressions in this project reached the screen because nothing
/// checked what was drawn: a window that lost its frame, an alert collapsed to
/// a sliver, a dropdown that would not fill its row. Each was visible in a
/// picture and invisible to every other kind of test.
///
/// Runs inside the app, behind `--snapshots`, because the views live in the
/// application target and nothing else can see them. `scripts/snapshots.sh`
/// drives it and does the comparing.
enum Snapshots {

    /// The states worth a picture, with the interface put into each by hand.
    ///
    /// Each is a screen someone can arrive at. States differing only in wording
    /// are left out, since this checks layout.
    @MainActor
    static func scenes() -> [(name: String, view: AnyView)] {
        let drive = Drive(
            id: "disk4s1", devicePath: "/dev/disk4s1", name: "Elements",
            sizeBytes: 500_072_185_856, connection: "USB · \(appString("External"))",
            kind: .microsoft, uuid: "SNAPSHOT-0000-0000-0000-000000000001")
        let linux = Drive(
            id: "disk5s2", devicePath: "/dev/disk5s2", name: "fedora",
            sizeBytes: 1_000_204_886_016, connection: "USB · \(appString("External"))",
            kind: .linux, uuid: "SNAPSHOT-0000-0000-0000-000000000002")
        // An image the engine reads for itself: no device, the file's own path
        // standing in for one.
        let image = Drive(
            id: "/Users/someone/Machines/win11.vhdx",
            devicePath: "/Users/someone/Machines/win11.vhdx", name: "win11",
            sizeBytes: 64_424_509_440, connection: appString("Disk Image"),
            kind: .linux, uuid: "/Users/someone/Machines/win11.vhdx")

        /// A whole window in a given state, which is what most scenes are.
        func model(_ configure: (AppModel) -> Void) -> AnyView {
            let m = AppModel()
            configure(m)
            return AnyView(ContentView().environmentObject(m))
        }

        let refused = URL(fileURLWithPath: "/Users/someone/Desktop/notes.pdf")

        /// The Open Drive sheet, with the range of verdicts it has to show.
        func openDriveSheet() -> AnyView {
            let m = AppModel()
            m.survey = [
                DriveSurvey.Entry(
                    id: "disk4s1", disk: "disk4", name: "Elements",
                    sizeBytes: 500_072_185_856, content: "Microsoft Basic Data",
                    verdict: .openable, drive: drive),
                DriveSurvey.Entry(
                    id: "disk6s1", disk: "disk6", name: "STICK", sizeBytes: 64_000_000_000,
                    content: "Microsoft Basic Data",
                    verdict: .macOSHasIt("/Volumes/STICK"), drive: nil),
                DriveSurvey.Entry(
                    id: "disk3s1", disk: "disk3", name: "Macintosh HD",
                    sizeBytes: 494_384_795_648, content: "Apple_APFS",
                    verdict: .system, drive: nil),
                DriveSurvey.Entry(
                    id: "disk7s2", disk: "disk7", name: "unknown", sizeBytes: 2_000_000_000,
                    content: "Apple_Boot", verdict: .unreadable, drive: nil),
            ]
            return AnyView(
                OpenDriveSheet().environmentObject(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor)))
        }

        /// The help sheet, which holds the longest prose in the app and is the
        /// part most easily left stating something no longer true.
        func helpSheet() -> AnyView {
            AnyView(
                HelpSheet()
                    .environmentObject(AppModel())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor)))
        }

        /// A sheet, rendered on its own. Sheets are separate windows and do not
        /// appear in a picture of the one underneath, so the only way to check
        /// one is to draw it by itself.
        func sheet(_ state: AppModel.ImageOpening) -> AnyView {
            AnyView(
                ImageOpenSheet(state: state)
                    .environmentObject(AppModel())
                    // Centred on a window-coloured ground. A sheet drawn on its
                    // own otherwise sits in a corner of the frame with the rest
                    // blank, and every later comparison is then mostly empty
                    // space.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor)))
        }

        return [
            ("permission", model { $0.phase = .needsPermission }),
            // The same screen, reached because a drive could not be put back
            // after a restart rather than because the app is new.
            (
                "permission-restore",
                model {
                    $0.phase = .needsPermission
                    $0.restoreBlocked = true
                }
            ),
            ("scanning", model { $0.phase = .scanning }),
            ("empty", model { $0.phase = .chooseDrive }),
            (
                "drives",
                model {
                    $0.drives = [drive, linux]
                    $0.phase = .chooseDrive
                }
            ),
            // A drive opened read-only: the pill beside the state, which is the
            // only place the list says so.
            (
                "drives-read-only",
                model {
                    $0.phase = .chooseDrive
                    $0.drives = [drive, linux]
                    $0.openMounts = ["/dev/disk4s1": "/Users/someone/Volumes/Elements"]
                    $0.readOnlyMounts = ["/Users/someone/Volumes/Elements"]
                    $0.space = [
                        "/Users/someone/Volumes/Elements": VolumeSpace(
                            free: 122_000_000_000, total: 500_072_185_856)
                    ]
                }
            ),
            // A drive open, with the free space and volume count the list shows
            // once it is. The row is at its widest here.
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
            // Mid-eject: the row reports what it is doing and cannot be pressed
            // again while it does.
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
            // row, naming its location in Disk Utility's words.
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
            // Opening a file, and a file that held nothing openable. Both are
            // sheets, so they are rendered as sheets.
            (
                "image-opening",
                sheet(.opening(URL(fileURLWithPath: "/Users/someone/Desktop/backup.img")))
            ),
            ("open-drive", openDriveSheet()),
            (
                "image-handed-over",
                sheet(
                    .handedToMacOS(
                        URL(fileURLWithPath: "/Users/someone/Desktop/photos.img"),
                        "/Volumes/PHOTOS"))
            ),
            (
                "image-refused",
                sheet(
                    .failed(
                        refused,
                        // Through the same interpolation the app uses, so the
                        // fixture does not become a catalogue key of its own.
                        appString(
                            "There is nothing in “\(refused.lastPathComponent)” that \(appName) can open."
                        )))
            ),
            // A drive that has just gone, reported where it was rather than at
            // the top of the screen.
            (
                "drives-departed",
                model {
                    $0.drives = [drive]
                    $0.showDeparted(name: "backup", index: 1)
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
            // macOS refused the removable-volumes permission: back to this
            // screen, which holds both the reason and the way to fix it.
            (
                "unlock-removable-refused",
                model {
                    $0.phase = .unlock(drive)
                    $0.removableAccess = false
                    $0.notice = appString(
                        "macOS refused \(appName) access to this drive. Switch on Removable Volumes below, then open it again."
                    )
                }
            ),
            // The tallest this screen goes: a passphrase to type, a warning
            // about the file's own format, and every permission outstanding.
            // Anything that fits here fits the rest.
            (
                "unlock-image-encrypted",
                model {
                    $0.phase = .unlock(image)
                    $0.containerFormats[image.id] = .vdi
                }
            ),
            // A drive found not to be encrypted, reported before anyone looks
            // for a password.
            (
                "unlock-unencrypted",
                model {
                    $0.phase = .unlock(drive)
                    $0.chosenFormat = .ntfs
                }
            ),
            // An image in a format written by a driver built here, which the
            // screen says plainly before anything is opened.
            (
                "unlock-image-writing-is-new",
                model {
                    $0.phase = .unlock(image)
                    $0.chosenFormat = .ntfs
                    $0.containerFormats[image.id] = .vdi
                }
            ),
            // And one that is read and never written, which offers a single
            // way to open it.
            (
                "unlock-image-read-only",
                model {
                    $0.phase = .unlock(image)
                    $0.chosenFormat = .ntfs
                    $0.containerFormats[image.id] = .vhdx
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
            // The same screen for a drive opened read-only, which must not
            // promise writing.
            (
                "mounted-read-only",
                model {
                    $0.phase = .mounted(drive, "/Volumes/Elements")
                    $0.mountedReadOnly = true
                }
            ),
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
            ("help", helpSheet()),
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
        ("ideal", NSSize(width: 640, height: 640)),
        ("min", NSSize(width: 580, height: 600)),
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
                for (sceneName, view) in scenes() {
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
        let window = OffScreenWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        if let appearance { window.appearance = appearance }
        // Far enough away that nobody sees it, and transparent so that nothing
        // is seen even if something puts it back. A run draws over a hundred of
        // these, so one appearing is a window flashing at the edge of the
        // screen again and again.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        // A window that is never brought on screen at all does not lay out.
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // The bitmap is made at one pixel to the point rather than taken from
        // the display, so a baseline recorded on a Retina Mac matches one
        // recorded anywhere else.
        let capture = {
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(frame.width), pixelsHigh: Int(frame.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return Data?.none }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }

        // Two captures that agree, rather than one taken after a fixed wait.
        // SwiftUI settles over a turn of the run loop, and an SF Symbol drawn
        // for the first time in a process settles later still: the chevron in
        // the drive list came out drawn in one run and missing in the next,
        // which made a baseline disagree with itself. Bounded, because a scene
        // that never settles is worth failing on rather than looping over.
        var previous: Data?
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let shot = capture()
            if let shot, shot == previous {
                window.orderOut(nil)
                return shot
            }
            previous = shot
        }
        window.orderOut(nil)
        return previous
    }
}

/// A window macOS will leave where it is put.
///
/// AppKit drags ordinary windows back onto a display, and `constrainFrameRect`
/// is what does it — which is why an off-screen origin alone was not enough.
/// The snapshot windows were being pulled to the edge of the screen and shown
/// there, once per picture.
private final class OffScreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
