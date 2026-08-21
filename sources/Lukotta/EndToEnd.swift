import AppKit
import LukottaCore
import SwiftUI

/// Drive a whole flow through the real app, without a person and without a
/// window.
///
/// The unit tests cover decisions and the snapshots cover what is drawn.
/// Neither covers a sequence: open a container, unlock it, watch the list
/// rebuild, eject it. Every bug in that flow so far has been a step undoing an
/// earlier one — a scan dropping a row, a save recording the wrong frame — and
/// only running the steps in order finds those.
///
/// Runs against the real engine, the real helper and the real hdiutil. Nothing
/// is stubbed, and nothing is drawn: it exits before the scene is ever built,
/// so no window appears anywhere.
enum EndToEnd {

    @MainActor private static var failures = 0
    @MainActor private static var checks = 0

    @MainActor
    static func runIfAsked() {
        guard let index = CommandLine.arguments.firstIndex(of: "--e2e") else { return }
        let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: --e2e <container.img> <passphrase>\n".utf8))
            exit(2)
        }
        let container = URL(fileURLWithPath: arguments[0])
        let passphrase = arguments[1]
        guard FileManager.default.fileExists(atPath: container.path) else {
            FileHandle.standardError.write(Data("no container at \(container.path)\n".utf8))
            exit(2)
        }

        print("container: \(container.lastPathComponent)")
        containerFlow(container: container, passphrase: passphrase)

        print("")
        print("\(checks - failures)/\(checks) steps passed")
        exit(failures > 0 ? 1 : 0)
    }

    // MARK: The flow

    @MainActor
    private static func containerFlow(container: URL, passphrase: String) {
        let model = AppModel()
        model.start()
        guard waitUntil("the app finishes scanning", condition: { !model.isScanning }) else {
            return
        }

        // 1. Open it.
        model.openImage(container)
        guard
            waitUntil(
                "the container opens", timeout: 60,
                condition: {
                    model.imageOpening == nil
                        && model.drives.contains { $0.uuid == container.path }
                })
        else {
            if case .failed(_, let why) = model.imageOpening { print("      \(why)") }
            return
        }
        guard let drive = model.drives.first(where: { $0.uuid == container.path }) else { return }
        check(drive.connection.contains(appString("Disk Image")), "it is listed as a disk image")

        // 2. Unlock it.
        model.choose(drive)
        model.credential = passphrase
        model.unlock(drive)
        guard
            waitUntil(
                "it unlocks and mounts", timeout: 180,
                condition: {
                    if case .mounted = model.phase { return true }
                    if case .failed = model.phase { return true }
                    return false
                })
        else { return }
        guard case .mounted(_, let mountPoint) = model.phase else {
            check(false, "it mounted rather than failing")
            return
        }
        check(FileManager.default.fileExists(atPath: mountPoint), "the mount point exists")

        // 3. The list is rebuilt while it is open.
        //
        // This is where it went wrong: a container with no partition table is a
        // row no scan can produce, so a rebuild dropped it, the app called the
        // drive unplugged, and threw the user back to the list from a drive
        // they had just opened.
        let before = model.phase
        let generation = model.scanGeneration
        model.refreshDrives()
        // For the results to be applied, not merely for the scan to be asked
        // for. Waiting on the phase would sail straight past: a rebuild does
        // not change it, so every assertion below would be about the list as it
        // was before.
        guard
            waitUntil(
                "the list rebuilds", condition: { model.scanGeneration > generation })
        else { return }
        check(
            model.drives.contains { $0.uuid == container.path },
            "the container is still listed after a rebuild")
        check(before.isMounted && model.phase.isMounted, "and the screen is still the open drive")
        check(model.departed.isEmpty, "and nothing was announced as disconnected")

        // 4. Eject it.
        model.eject(mountPoint)
        guard waitUntil("it ejects", timeout: 120, condition: { !model.isEjecting }) else {
            return
        }
        check(model.ejectProblem == nil, "ejecting reported no problem")
        guard
            waitUntil(
                "the container is detached", timeout: 30,
                condition: { !model.drives.contains { $0.uuid == container.path } })
        else { return }
        check(
            !FileManager.default.fileExists(atPath: drive.devicePath),
            "and its device is gone, so the file is a file again")
    }

    // MARK: Running the loop

    /// Wait for something to become true, pumping the run loop while it does.
    ///
    /// Everything here is asynchronous and lands on the main actor, so the test
    /// has to let the main actor run rather than blocking it.
    @MainActor
    @discardableResult
    private static func waitUntil(
        _ what: String, timeout: TimeInterval = 30, condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                check(false, "\(what) (gave up after \(Int(timeout))s)")
                return false
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(true, what)
        return true
    }

    @MainActor
    private static func check(_ passed: Bool, _ what: String) {
        checks += 1
        if passed {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)")
        }
    }
}

extension AppModel.Phase {
    var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }
}
