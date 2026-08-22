import Foundation

// MARK: - Engine state

public struct EngineMount: Equatable, Sendable {
    public let devicePath: String  // /dev/disk4s1
    public let mountPoint: String  // /Volumes/BACKUP
}

/// What the engine itself reports, rather than what we can infer by parsing
/// `mount` output. Runs unprivileged, so the app can check state at any time.
public enum EngineStatus {
    public static func current() -> [EngineMount] {
        guard let engine = EnginePaths.anylinuxfs,
            FileManager.default.fileExists(atPath: engine.path)
        else { return [] }
        let p = Process()
        p.executableURL = engine
        p.arguments = ["status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// "/dev/disk4s1 on /Volumes/BACKUP (ntfs3, ...) VM[cpus: 4, ram: 2048 MiB]"
    public static func parse(_ text: String) -> [EngineMount] {
        var mounts: [EngineMount] = []
        for line in text.components(separatedBy: .newlines) {
            guard let onRange = line.range(of: " on "),
                let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            let dev = String(line[line.startIndex..<onRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let mp = String(line[onRange.upperBound..<parenRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Any absolute source, not only /dev/ — the engine also mounts disk
            // images — and the lvm:/raid: identifiers it uses for volumes inside
            // a container. A mount it reports is a mount worth resuming.
            guard dev.hasPrefix("/") || dev.hasPrefix("lvm:") || dev.hasPrefix("raid:"),
                mp.hasPrefix("/")
            else { continue }
            mounts.append(EngineMount(devicePath: dev, mountPoint: mp))
        }
        return mounts
    }

    /// Mount points macOS still shows for a microVM that is no longer running.
    ///
    /// If the virtual machine goes away with an NFS mount still up — it
    /// crashed, or was killed — the mount outlives it, and macOS keeps
    /// reporting "server connections interrupted" until something clears it.
    /// That dialog belongs to the system and cannot be suppressed; the dead
    /// mount behind it can be removed, which is the part we can do.
    public static func stale() -> [String] {
        let live = current().map(\.mountPoint)
        // A multi-volume mount nests per-volume mounts inside the primary, and
        // the engine reports only the primary: anything under a live mount is
        // alive too, not abandoned. What is genuinely stale is cleared deepest
        // first, or a parent would be detached with its children still mounted.
        return engineMountPoints(in: mountTable())
            .filter { point in
                !live.contains(point) && !live.contains { point.hasPrefix($0 + "/") }
            }
            .sorted {
                $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count
            }
    }

    private static func mountTable() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Which entries of `mount` output this engine is responsible for.
    ///
    /// Recognised by the export path, so a network share the user mounted
    /// themselves is never touched: the engine exports under /mnt, and
    /// Lukotta's multi-volume action exports under /run.
    public static func engineMountPoints(in text: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.contains("(nfs"),
                line.contains(":/mnt/") || line.contains(":/run/"),
                let onRange = line.range(of: " on "),
                let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            let mp = String(line[onRange.upperBound..<parenRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if mp.hasPrefix("/") { found.append(mp) }
        }
        return found
    }

    /// NFS mounts nested under a drive's mount point — one per logical volume
    /// when a container held several. Read from the system mount table because
    /// the engine's status reports only the primary mount, and the nested ones
    /// are what the user actually opens.
    public static func nestedVolumes(under mountPoint: String) -> [String] {
        nestedVolumes(under: mountPoint, in: mountTable())
    }

    /// "server:/run/T7/HOME on /Volumes/T7/HOME (nfs, ...)"
    public static func nestedVolumes(under mountPoint: String, in mountText: String) -> [String] {
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        var found: [String] = []
        for line in mountText.components(separatedBy: .newlines) {
            guard let onRange = line.range(of: " on "),
                let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex),
                line[parenRange.upperBound...].hasPrefix("nfs")
            else { continue }
            let mp = String(line[onRange.upperBound..<parenRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if mp.hasPrefix(prefix) { found.append(mp) }
        }
        return found
    }

    /// Detach a mount whose server is already gone. The ordinary unmount asks
    /// the server to co-operate, which a dead one cannot do.
    @discardableResult
    public static func forceUnmount(mountPoint: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/umount")
        p.arguments = ["-f", mountPoint]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// How long the engine is given to tear a mount down before it is treated
    /// as stuck.
    ///
    /// It is told to wait thirty seconds for the virtual machine, so anything
    /// past that is the engine itself not returning rather than the machine
    /// being slow. Ten seconds of margin, and then the interface gets an answer
    /// instead of a spinner that never stops.
    public static let unmountTimeout: TimeInterval = 40

    /// Unmount and wait for the microVM to exit. Unprivileged - the engine
    /// tears down the VM it started, so ejecting never needs a password.
    @discardableResult
    public static func unmount(mountPoint: String, timeout: TimeInterval = unmountTimeout) -> (
        ok: Bool, message: String
    ) {
        guard let engine = EnginePaths.anylinuxfs else { return (false, "Engine missing.") }
        let p = Process()
        p.executableURL = engine
        p.arguments = ["unmount", mountPoint, "--wait-for-vm", "30"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "Could not run the engine.") }

        // Give up rather than wait for ever. Reading the pipes to the end would
        // itself block on a process that never finishes, so the deadline is
        // watched first and the output read after.
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (
                false,
                appString(
                    "The drive did not finish ejecting. It may still be in use, so try again or eject it in Finder."
                )
            )
        }

        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let combined = (o + "\n" + e).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus == 0 { return (true, combined) }
        // Busy volumes are the common case and deserve a usable sentence.
        if combined.lowercased().contains("busy") || combined.lowercased().contains("in use") {
            return (
                false, "The drive is in use. Close any open files or apps using it, then try again."
            )
        }
        return (false, combined.isEmpty ? "The drive could not be ejected." : combined)
    }
}
