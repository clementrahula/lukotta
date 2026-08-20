import Foundation

// MARK: - Mounting

public struct MountResult: Sendable {
    public let mountPoint: String
    public let transcript: String
}

/// Runs the privileged mount under a single macOS authorisation.
///
/// Reading a raw /dev/disk and creating an NFS mount both require root. The
/// user is asked once, by macOS itself, and the entire mount runs under that
/// one approval - there is no persistent privileged helper and nothing is
/// installed outside the app bundle.
public enum Mounter {
    public static func mount(
        drive: Drive,
        credential: String,
        volume: LogicalVolume? = nil,
        workspace: Workspace,
        progress: @escaping (String) -> Void
    ) throws -> MountResult {

        guard let engine = EnginePaths.anylinuxfs,
            FileManager.default.fileExists(atPath: engine.path)
        else {
            throw EngineError.missingEngine
        }
        try EngineEnvironment.prepare(progress: progress)
        let fifo = try workspace.makeCredentialPipe()
        let log = workspace.root.appendingPathComponent("mount.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        // Build the privileged command. The credential is read from a FIFO, so
        // it never appears in an argument list, an exported environment, or on
        // disk. DYLD_* must be set inside the elevated shell because macOS
        // strips those variables across a privilege boundary.
        var parts: [String] = []
        let libs = EnginePaths.libraryPaths().joined(separator: ":")
        if !libs.isEmpty {
            parts.append("export DYLD_LIBRARY_PATH=\(shellQuoted(libs))")
            parts.append("export DYLD_FALLBACK_LIBRARY_PATH=\(shellQuoted(libs))")
        }
        // `do shell script ... with administrator privileges` runs the command
        // directly as root rather than through sudo, so SUDO_UID/SUDO_GID are
        // absent and the engine refuses to start ("must not be run directly by
        // root"). Supply the real invoking user explicitly.
        parts.append("export SUDO_UID=\(getuid())")
        parts.append("export SUDO_GID=\(getgid())")

        // Finder shows an NFS mount under its server name, which the engine
        // derives from the last path component it is given. A symlink named
        // after the drive is what stops it reading "disk4s1.local".
        let aliasPath =
            (try? workspace.makeDeviceAlias(
                named: drive.name,
                target: drive.devicePath))?.path

        let expectURL = workspace.root.appendingPathComponent("discover.exp")
        try MountScript.expectDriver.write(to: expectURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: expectURL.path)

        let script = MountScript.build(
            MountScript.Inputs(
                enginePath: engine.path,
                devicePath: drive.devicePath,
                driveName: drive.name,
                kind: drive.kind,
                volume: volume,
                aliasPath: aliasPath,
                fifoPath: fifo.path,
                logPath: log.path,
                discoverLogPath: workspace.root.appendingPathComponent("discover.log").path,
                expectScriptPath: expectURL.path,
                configPath: EngineConfig.path,
                libraryPaths: EnginePaths.libraryPaths(),
                uid: getuid(),
                gid: getgid(),
                cores: MountScript.VirtualMachine.cores,
                ramMiB: MountScript.VirtualMachine.ramMiB))

        let scriptURL = workspace.root.appendingPathComponent("mount.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path)

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = [
            "-e", "with timeout of 1800 seconds",
            "-e",
            "do shell script \(appleScriptQuoted("/bin/sh " + shellQuoted(scriptURL.path))) with administrator privileges",
            "-e", "end timeout",
        ]
        let osaErr = Pipe()
        osa.standardOutput = FileHandle.nullDevice
        osa.standardError = osaErr

        progress("Waiting for your administrator approval…")
        try osa.run()

        // Hand the credential over once the elevated shell opens the FIFO. This
        // blocks until the reader arrives, so it is done off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            if let fh = FileHandle(forWritingAtPath: fifo.path) {
                fh.write(Data(credential.utf8))
                try? fh.close()
            }
        }

        // Stream the engine's own output while it works.
        let streamer = LogStreamer(path: log.path, onLine: progress)
        streamer.start()
        osa.waitUntilExit()
        streamer.stop()

        let transcript = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let osaMessage =
            String(
                data: osaErr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""

        if osa.terminationStatus != 0 {
            if osaMessage.contains("-128") || osaMessage.lowercased().contains("user canceled") {
                throw EngineError.authorisationCancelled
            }
            throw EngineError.mountFailed(
                summary: Diagnosis.summarise(transcript, fallback: osaMessage),
                detail: transcript.isEmpty ? osaMessage : transcript)
        }

        guard let mountPoint = discoverMountPoint(for: drive, transcript: transcript) else {
            throw EngineError.mountFailed(
                summary: "The engine reported success but the drive did not appear in Finder.",
                detail: transcript)
        }
        return MountResult(mountPoint: mountPoint, transcript: transcript)
    }

    /// Ask the engine where the volume landed; fall back to scraping only if it
    /// has nothing to say.
    public static func discoverMountPoint(for drive: Drive, transcript: String) -> String? {
        // An LVM mount is reported as "lvm:<vg>:<disk>:<lv>" rather than by the
        // device path, so match on the disk identifier it carries.
        if let m = EngineStatus.current().first(where: {
            $0.devicePath == drive.devicePath
                || (!drive.id.isEmpty && $0.devicePath.contains(drive.id))
        }) {
            return m.mountPoint
        }
        return scrapeMountPoint(for: drive, transcript: transcript)
    }

    private static func scrapeMountPoint(for drive: Drive, transcript: String) -> String? {
        for line in transcript.components(separatedBy: .newlines) {
            guard let r = line.range(of: "/Volumes/") else { continue }
            let candidate = String(line[r.lowerBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.,)"))
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        // Fall back to asking the system for NFS mounts under /Volumes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: .newlines) where line.contains(" on /Volumes/") {
            guard line.contains("nfs") else { continue }
            guard let onRange = line.range(of: " on "),
                let typeRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            return String(line[onRange.upperBound..<typeRange.lowerBound])
        }
        return nil
    }
}
