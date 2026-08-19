import Foundation

// MARK: - Shell / AppleScript quoting

func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptQuoted(_ s: String) -> String {
    "\"" + s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: - Drives

struct Drive: Identifiable, Hashable {
    let id: String          // disk4s1
    let devicePath: String  // /dev/disk4s1
    let name: String        // volume name, or a synthesised one
    let sizeBytes: Int64
    let mediaName: String   // enclosure / product name

    var sizeDescription: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }
}

/// Finds partitions that could be BitLocker volumes.
///
/// Without root we cannot read the FVE header, so classification is by GPT
/// partition type: BitLocker volumes are "Microsoft Basic Data", the same type
/// plain NTFS uses. The UI is honest about that rather than claiming certainty.
enum DriveScanner {
    static func scan() -> [Drive] {
        guard let plist = runPlist(["/usr/sbin/diskutil", "list", "-plist", "physical"]),
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var drives: [Drive] = []
        for disk in allDisks {
            let mediaName = disk["MediaName"] as? String ?? "Disk"
            guard let partitions = disk["Partitions"] as? [[String: Any]] else { continue }
            for part in partitions {
                guard let ident = part["DeviceIdentifier"] as? String else { continue }
                let content = part["Content"] as? String ?? ""
                // Microsoft Basic Data covers both BitLocker and plain NTFS.
                guard content == "Microsoft Basic Data" else { continue }
                let size = (part["Size"] as? NSNumber)?.int64Value ?? 0
                let name = (part["VolumeName"] as? String) ?? mediaName
                drives.append(Drive(id: ident,
                                    devicePath: "/dev/\(ident)",
                                    name: name,
                                    sizeBytes: size,
                                    mediaName: mediaName))
            }
        }
        return drives
    }

    private static func runPlist(_ argv: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data,
                                                           options: [],
                                                           format: nil)) as? [String: Any]
    }
}

// MARK: - Credential handling

enum Credential {
    /// Normalise a credential using the shipped validator, which distinguishes a
    /// 48-digit numerical recovery password from an ordinary volume password.
    /// Returns the normalised value, or a human-readable reason for refusing it.
    static func normalise(_ raw: String) -> Result<String, EngineError> {
        guard let validator = EnginePaths.validator,
              FileManager.default.fileExists(atPath: validator.path) else {
            // Without the validator, forward the credential untouched rather
            // than blocking the user.
            return .success(raw)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [validator.path, raw]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return .success(raw)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        if p.terminationStatus == 0 {
            let value = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .newlines) ?? raw
            return .success(value)
        }
        let reason = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "That credential was not accepted."
        return .failure(.credentialRejected(reason))
    }

    /// Live feedback while typing, without validating hard enough to be annoying.
    static func hint(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter { $0.isNumber }
        let onlyKeyChars = trimmed.allSatisfy { $0.isNumber || $0 == "-" || $0 == " " }
        guard onlyKeyChars, digits.count >= 20 else { return nil }
        if digits.count == 48 { return "Recovery key — 48 digits" }
        return "Recovery key — \(digits.count) of 48 digits"
    }
}

// MARK: - Mounting

struct MountResult {
    let mountPoint: String
    let transcript: String
}

/// Runs the privileged mount under a single macOS authorisation.
///
/// Reading a raw /dev/disk and creating an NFS mount both require root. The
/// user is asked once, by macOS itself, and the entire mount runs under that
/// one approval - there is no persistent privileged helper and nothing is
/// installed outside the app bundle.
enum Mounter {
    static func mount(drive: Drive,
                      credential: String,
                      workspace: Workspace,
                      progress: @escaping (String) -> Void) throws -> MountResult {

        guard let engine = EnginePaths.anylinuxfs,
              FileManager.default.fileExists(atPath: engine.path) else {
            throw EngineError.missingEngine
        }
        guard let rootfs = EnginePaths.embeddedRootfs ?? EnginePaths.developmentRootfs else {
            throw EngineError.missingRootfs
        }

        progress("Preparing a private workspace…")
        try workspace.linkRootfs(from: rootfs)
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
        parts.append("export HOME=\(shellQuoted(workspace.homeDirectory.path))")
        let cmd = "ALFS_PASSPHRASE=\"$(cat \(shellQuoted(fifo.path)))\" "
            + shellQuoted(engine.path)
            + " mount --ignore-permissions -t ntfs3 "
            + shellQuoted(drive.devicePath)
            + " > \(shellQuoted(log.path)) 2>&1"
        parts.append(cmd)
        let script = parts.joined(separator: "; ")

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = [
            "-e", "with timeout of 1800 seconds",
            "-e", "do shell script \(appleScriptQuoted(script)) with administrator privileges",
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
        let osaMessage = String(data: osaErr.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""

        if osa.terminationStatus != 0 {
            if osaMessage.contains("-128") || osaMessage.lowercased().contains("user canceled") {
                throw EngineError.authorisationCancelled
            }
            throw EngineError.mountFailed(summary: Diagnosis.summarise(transcript, fallback: osaMessage),
                                          detail: transcript.isEmpty ? osaMessage : transcript)
        }

        guard let mountPoint = discoverMountPoint(for: drive, transcript: transcript) else {
            throw EngineError.mountFailed(
                summary: "The engine reported success but the drive did not appear in Finder.",
                detail: transcript)
        }
        return MountResult(mountPoint: mountPoint, transcript: transcript)
    }

    /// Find where the volume actually landed, preferring the engine's own words.
    static func discoverMountPoint(for drive: Drive, transcript: String) -> String? {
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

/// Turns raw engine output into one plain sentence, without hiding the original.
enum Diagnosis {
    static func summarise(_ transcript: String, fallback: String) -> String {
        let lower = transcript.lowercased()
        if lower.contains("wrong key") || lower.contains("invalid passphrase")
            || lower.contains("no key available") || lower.contains("keyslot") {
            return "That password or recovery key did not unlock this drive."
        }
        if lower.contains("not a valid bitlocker") || lower.contains("unknown filesystem")
            || lower.contains("no bitlocker") {
            return "This partition does not look like a BitLocker volume."
        }
        if lower.contains("already mounted") {
            return "macOS already has this drive mounted. Eject it in Finder and try again."
        }
        if lower.contains("hypervisor") || lower.contains("hv_") || lower.contains("vmm") {
            return "The virtualisation engine could not start. A restart usually clears this."
        }
        if lower.contains("resource busy") || lower.contains("device busy") {
            return "The drive is busy. Close anything using it, then try again."
        }
        // Prefer the engine's last meaningful line over a generic message.
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last, last.count > 8 { return last }
        let fb = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fb.isEmpty ? "The drive could not be opened." : fb
    }
}

/// Tails a growing log file and reports new lines.
final class LogStreamer {
    private let path: String
    private let onLine: (String) -> Void
    private var source: DispatchSourceTimer?
    private var offset: UInt64 = 0

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.drain() }
        source = timer
        timer.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        drain()
    }

    private func drain() {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { onLine(t) }
        }
    }
}
