// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

// The test harnesses are built into the pre-release and into a plain local
// build, and out of the app people are given: nobody running Lukotta has a use
// for a flag that draws the README pictures or opens every fixture, and what is not
// compiled in cannot be reached by passing one.
#if DEVTOOLS

    import AppKit
    import LukottaCore
    import SwiftUI

    /// README pictures, behind `--screenshots`.
    enum Screenshots {

        /// The drive list as the app is meant to be seen: one screen
        /// carrying what this application is for.
        ///
        /// Every row is made up here. Nothing is read from this Mac, no
        /// drive is attached and no name belongs to anybody -- which is the
        /// only way to picture a BitLocker drive on a Mac that has none,
        /// and the only way to publish a picture of somebody's disks
        /// without publishing somebody's disks.
        ///
        /// Between them the five rows carry: hardware and files, BitLocker
        /// and LUKS, ext4 and Btrfs, a container holding three volumes, a
        /// drive opened read-only, one still locked, mount points, free
        /// space, and how many more can be opened.
        @MainActor
        static func showcase() -> AnyView {
            // A made-up home directory rather than this Mac's: these pictures
            // are published, and the account name on the machine that drew them
            // is nobody's business.
            let home = "/Users/kim"
            func image(_ name: String, _ bytes: Int64) -> Drive {
                Drive(
                    id: "\(home)/Machines/\(name)",
                    devicePath: "\(home)/Machines/\(name)", name: name,
                    sizeBytes: bytes, connection: appString("Disk Image"),
                    kind: .linux, uuid: "\(home)/Machines/\(name)")
            }

            // Volume labels are short and upper case because that is how
            // Windows writes them; files are lower case because that is
            // what they are. The two conventions tell a reader which rows
            // are hardware before they have read a word.
            let backup = Drive(
                id: "disk4s2", devicePath: "/dev/disk4s2", name: "BACKUP",
                sizeBytes: 2_000_000_000_000,
                connection: "USB · \(appString("External"))",
                kind: .microsoft, uuid: "SHOWCASE-0000-0000-0000-00000000000B")
            let photos = Drive(
                id: "disk6s2", devicePath: "/dev/disk6s2", name: "PHOTOS",
                sizeBytes: 4_000_000_000_000,
                connection: "USB · \(appString("External"))",
                kind: .microsoft, uuid: "SHOWCASE-0000-0000-0000-00000000000P")
            let linux = image("linux-vm.img", 64_000_000_000)
            let server = image("server-vm.img", 32_000_000_000)
            let lab = image("lab-machine.vdi", 80_000_000_000)

            let m = AppModel()
            m.phase = .chooseDrive
            m.drives = [backup, linux, server, lab, photos]

            // What has been read from each: the lock, and what is
            // behind it once it is open.
            m.knownFormats = [
                backup.id: .bitlocker, photos.id: .bitlocker,
                linux.id: .luks, server.id: .luks, lab.id: .ntfs,
            ]
            m.knownFilesystems = [
                backup.id: "NTFS", linux.id: "ext4", server.id: "Btrfs",
            ]
            m.containerFormats = [lab.id: .vdi]

            // Open, and where. PHOTOS is not: a list where everything
            // is unlocked never shows the padlock, which is the state
            // this application exists to change.
            let mounts: [(Drive, String)] = [
                (backup, "\(home)/Volumes/BACKUP"),
                (linux, "\(home)/Volumes/linux-vm"),
                (server, "\(home)/Volumes/server-vm"),
                (lab, "\(home)/Volumes/lab-machine"),
            ]
            for (drive, point) in mounts { m.openMounts[drive.devicePath] = point }
            m.readOnlyMounts = ["\(home)/Volumes/lab-machine"]
            m.volumeCount = ["\(home)/Volumes/linux-vm": 3]
            m.space = [
                "\(home)/Volumes/BACKUP": VolumeSpace(
                    free: 1_400_000_000_000, total: 2_000_000_000_000),
                "\(home)/Volumes/linux-vm": VolumeSpace(
                    free: 22_000_000_000, total: 64_000_000_000),
                "\(home)/Volumes/server-vm": VolumeSpace(
                    free: 9_600_000_000, total: 32_000_000_000),
                "\(home)/Volumes/lab-machine": VolumeSpace(
                    free: 41_000_000_000, total: 80_000_000_000),
            ]
            m.capacity = (limitCount: Capacity.wanted, openCount: 4)
            return AnyView(ContentView().environmentObject(m))
        }

        @MainActor
        static func runIfAsked() {
            guard let index = CommandLine.arguments.firstIndex(of: "--screenshots") else { return }

            // Headless: no Dock icon, no window on screen.
            NSApplication.shared.setActivationPolicy(.prohibited)

            // The notice is a sheet: a real on-screen window.
            UserDefaults.standard.set(true, forKey: AppModel.earlyNoticeKey)

            // A flag is not a directory.
            guard CommandLine.arguments.count > index + 1,
                !CommandLine.arguments[index + 1].hasPrefix("-")
            else {
                FileHandle.standardError.write(Data("usage: --screenshots <directory>\n".utf8))
                exit(2)
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let language = Locale.preferredLanguages.first ?? "en"
            let size = NSSize(width: 640, height: 640)
            for (name, appearance) in [
                ("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua)),
            ] {
                // Drawn twice: this screen asks the window for a width of
                // its own and gets it a moment after the first layout, so a
                // single pass at the frame we chose leaves an empty margin
                // where the window pulled itself in. The first pass is only
                // there to be told what it settled on.
                var settled = size
                _ = render(showcase(), appearance: appearance, size: size) { settled = $0 }
                guard
                    let png = render(
                        showcase(), appearance: appearance, size: settled, scale: 2)
                else {
                    FileHandle.standardError.write(Data("could not draw \(language)\n".utf8))
                    exit(1)
                }
                try? png.write(
                    to: directory.appendingPathComponent("\(language)-\(name).png"))
            }
            print("drew \(language)")
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
        /// - Parameter scale: pixels to the point. Two for a picture somebody will look at on a Retina display, where
        ///   one pixel to the point is visibly soft.
        /// - Parameter whenSettled: handed the size the window ended up at,
        ///   which is not always the one it was given.
        private static func render(
            _ view: some View, appearance: NSAppearance?, size: NSSize, scale: Int = 1,
            whenSettled: ((NSSize) -> Void)? = nil
        ) -> Data? {
            let frame = NSRect(origin: .zero, size: size)
            // Which way round the interface goes is a property of the language the
            // run was given. AppKit works it out once an application has finished
            // launching, and a screenshot process never does: without this every
            // language draws left to right, including the two the mirroring exists
            // for, and the pictures would show Arabic in a Latin layout.
            let language = Locale.preferredLanguages.first ?? "en"
            let direction: LayoutDirection =
                Locale.Language(identifier: language).characterDirection == .rightToLeft
                ? .rightToLeft : .leftToRight
            let hosting = NSHostingView(
                rootView: AnyView(view.environment(\.layoutDirection, direction)))
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

            // The bitmap is made at a density this code decides rather than taken
            // from the display, so a picture meant for a Retina display is drawn
            // at that density on any Mac.
            let capture = {
                guard
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(frame.width) * scale,
                        pixelsHigh: Int(frame.height) * scale,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return Data?.none }
                // The rep counts pixels; its size is in points. Saying both is what
                // makes the drawing happen at scale rather than the same drawing
                // being stretched over more pixels.
                rep.size = frame.size
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                return rep.representation(using: .png, properties: [:])
            }

            // Two captures that agree, rather than one taken after a fixed wait.
            // SwiftUI settles over a turn of the run loop, and an SF Symbol drawn
            // for the first time in a process settles later still: the chevron in
            // the drive list came out drawn in one run and missing in the next,
            // which made two runs disagree. Bounded, because a scene
            // that never settles is worth failing on rather than looping over.
            var previous: Data?
            for _ in 0..<8 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let shot = capture()
                if let shot, shot == previous {
                    window.orderOut(nil)
                    whenSettled?(hosting.bounds.size)
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
    /// The screenshot windows were being pulled to the edge of the screen and shown
    /// there, once per picture.
    private final class OffScreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

#endif
