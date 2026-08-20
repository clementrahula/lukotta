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
            // Any absolute source, not only /dev/. The engine also mounts disk
            // images, and a mount it reports is a mount worth resuming.
            guard dev.hasPrefix("/"), mp.hasPrefix("/") else { continue }
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
        let live = Set(current().map(\.mountPoint))
        return engineMountPoints(in: mountTable()).filter { !live.contains($0) }
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
    /// Recognised by the export path the engine always uses, so a network
    /// share the user mounted themselves is never touched.
    public static func engineMountPoints(in text: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.contains("(nfs"), line.contains(":/mnt/"),
                let onRange = line.range(of: " on "),
                let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            let mp = String(line[onRange.upperBound..<parenRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if mp.hasPrefix("/") { found.append(mp) }
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

    /// Unmount and wait for the microVM to exit. Unprivileged - the engine
    /// tears down the VM it started, so ejecting never needs a password.
    @discardableResult
    public static func unmount(mountPoint: String) -> (ok: Bool, message: String) {
        guard let engine = EnginePaths.anylinuxfs else { return (false, "Engine missing.") }
        let p = Process()
        p.executableURL = engine
        p.arguments = ["unmount", mountPoint, "--wait-for-vm", "30"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "Could not run the engine.") }
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
