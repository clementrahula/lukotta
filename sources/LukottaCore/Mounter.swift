// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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
/// one approval. This is the route taken when the privileged helper is not
/// registered; with it, unlocking asks for nothing.
public enum Mounter {
    /// Open a drive with the engine.
    ///
    /// `elevated` is what decides whether macOS is asked to authorise the
    /// command. A physical drive needs it, `/dev/diskNsM` being mode 640 owned by
    /// root and the operator group. A container file attached by this user does
    /// not: the device node is theirs, and the NFS mount the engine makes is a
    /// user mount. Run unelevated, the engine mounts under `~/Volumes` rather
    /// than `/Volumes`, which is the visible difference.
    public static func mount(
        drive: Drive,
        credential: String,
        volume: LogicalVolume? = nil,
        workspace: Workspace,
        elevated: Bool = true,
        readOnly: Bool = false,
        progress: @escaping (String) -> Void
    ) throws -> MountResult {

        guard let engine = EnginePaths.anylinuxfs,
            FileManager.default.fileExists(atPath: engine.path)
        else {
            throw EngineError.missingEngine
        }
        try EngineEnvironment.prepare(progress: progress)
        // The engine writes three logs per mount into ~/Library/Logs and never
        // takes them back. Which ones it wrote is knowable only by looking
        // before and after: a Mac with anylinuxfs of its own writes files named
        // exactly the same, and those are not ours to remove.
        let logsBefore = Housekeeping.EngineLogs.present()
        defer { Housekeeping.EngineLogs.claimAppeared(since: logsBefore) }
        let fifo = try workspace.makeCredentialPipe()
        let log = workspace.root.appendingPathComponent("mount.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

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
                engineHome: EngineEnvironment.engineHome.path,
                libraryPaths: EnginePaths.libraryPaths(),
                uid: getuid(),
                gid: getgid(),
                cores: MountScript.VirtualMachine.cores,
                ramMiB: MountScript.VirtualMachine.ramMiB,
                elevated: elevated,
                readOnly: readOnly))

        let scriptURL = workspace.root.appendingPathComponent("mount.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path)

        let osa = Process()
        let osaErr = Pipe()
        if elevated {
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = [
                "-e", "with timeout of 1800 seconds",
                "-e",
                "do shell script \(appleScriptQuoted("/bin/sh " + shellQuoted(scriptURL.path))) with administrator privileges",
                "-e", "end timeout",
            ]
        } else {
            // Straight to the shell. Nothing here needs a privilege the user
            // does not already have over their own file.
            osa.executableURL = URL(fileURLWithPath: "/bin/sh")
            osa.arguments = [scriptURL.path]
        }
        osa.standardOutput = FileHandle.nullDevice
        osa.standardError = osaErr

        // Which engine helpers were already running, so that the ones this
        // attempt starts can be told apart from the ones serving drives that
        // are already open. Read before anything is started.
        let helpersBefore = EngineProcesses.running()

        if elevated { progress("Waiting for your administrator approval…") }
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
            EngineProcesses.stopWhatStartedSince(helpersBefore)
            if osaMessage.contains("-128") || osaMessage.lowercased().contains("user canceled") {
                throw EngineError.authorisationCancelled
            }
            throw EngineError.mountFailed(
                summary: Diagnosis.summarise(transcript, fallback: osaMessage),
                detail: transcript.isEmpty ? osaMessage : transcript)
        }

        guard let mountPoint = discoverMountPoint(for: drive, transcript: transcript) else {
            // Nothing mounted, so nothing will ever eject: the virtual machine
            // and its network helper would stay until the Mac is restarted, and
            // one of them keeps the image file locked against the next attempt.
            EngineProcesses.stopWhatStartedSince(helpersBefore)
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
                || drive.owns($0.devicePath)
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
        for line in mountTable().components(separatedBy: .newlines)
        where line.contains(" on /Volumes/") {
            guard line.contains("nfs") else { continue }
            guard let onRange = line.range(of: " on "),
                let typeRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            return String(line[onRange.upperBound..<typeRange.lowerBound])
        }
        return nil
    }
}
