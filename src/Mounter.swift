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

/// What we can tell about a partition before anything is unlocked.
enum VolumeKind: String, Hashable {
    /// GPT "Microsoft Basic Data" — BitLocker or plain NTFS, indistinguishable
    /// until an unlock is attempted.
    case microsoft
    /// A Linux partition — LUKS, or an unencrypted Linux filesystem.
    case linux

    var summary: String {
        switch self {
        case .microsoft: return "BitLocker or NTFS"
        case .linux:     return "LUKS or Linux filesystem"
        }
    }
}

struct Drive: Identifiable, Hashable {
    let id: String          // disk4s1
    let devicePath: String  // /dev/disk4s1
    let name: String        // best human-readable label we can find
    let sizeBytes: Int64
    let connection: String  // e.g. "USB · External"
    let kind: VolumeKind

    var sizeDescription: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }

    var subtitle: String {
        connection.isEmpty ? "\(sizeDescription) · \(kind.summary) · \(id)"
                           : "\(sizeDescription) · \(connection) · \(kind.summary) · \(id)"
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
            let wholeIdent = disk["DeviceIdentifier"] as? String
            let wholeInfo = wholeIdent.flatMap { info(for: $0) } ?? [:]
            // The product name of the physical drive is what a person recognises
            // ("Elements 25A2"), and it is absent from the list plist.
            let product = firstNonEmpty(wholeInfo["MediaName"] as? String,
                                        wholeInfo["IORegistryEntryName"] as? String)
            let bus = wholeInfo["BusProtocol"] as? String
            let internalDisk = wholeInfo["Internal"] as? Bool ?? false

            guard let partitions = disk["Partitions"] as? [[String: Any]] else { continue }
            for part in partitions {
                guard let ident = part["DeviceIdentifier"] as? String else { continue }
                // "Microsoft Basic Data" covers BitLocker and plain NTFS alike;
                // Linux types cover LUKS and unencrypted Linux filesystems.
                // Nothing can be distinguished further without reading the
                // header, which needs root, so the UI stays honest about it.
                let content = (part["Content"] as? String) ?? ""
                let kind: VolumeKind
                switch content {
                case "Microsoft Basic Data":
                    kind = .microsoft
                case "Linux Filesystem", "Linux_Filesystem",
                     "Linux LVM", "Linux_LVM", "Linux RAID", "Linux_RAID":
                    kind = .linux
                default:
                    continue
                }

                let partInfo = info(for: ident) ?? [:]
                let size = (part["Size"] as? NSNumber)?.int64Value
                    ?? (partInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0

                let label = firstNonEmpty(part["VolumeName"] as? String,
                                          partInfo["VolumeName"] as? String,
                                          product,
                                          partInfo["IORegistryEntryName"] as? String) ?? ident

                var connection: [String] = []
                if let bus, !bus.isEmpty { connection.append(bus) }
                connection.append(internalDisk ? "Internal" : "External")

                drives.append(Drive(id: ident,
                                    devicePath: "/dev/\(ident)",
                                    name: label,
                                    sizeBytes: size,
                                    connection: connection.joined(separator: " · "),
                                    kind: kind))
            }
        }
        return drives
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return nil
    }

    private static func info(for ident: String) -> [String: Any]? {
        runPlist(["/usr/sbin/diskutil", "info", "-plist", ident])
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

// MARK: - Engine state

struct EngineMount: Equatable {
    let devicePath: String   // /dev/disk4s1
    let mountPoint: String   // /Volumes/BACKUP
}

/// What the engine itself reports, rather than what we can infer by parsing
/// `mount` output. Runs unprivileged, so the app can check state at any time.
enum EngineStatus {
    static func current() -> [EngineMount] {
        guard let engine = EnginePaths.anylinuxfs,
              FileManager.default.fileExists(atPath: engine.path) else { return [] }
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
    static func parse(_ text: String) -> [EngineMount] {
        var mounts: [EngineMount] = []
        for line in text.components(separatedBy: .newlines) {
            guard let onRange = line.range(of: " on "),
                  let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex)
            else { continue }
            let dev = String(line[line.startIndex..<onRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let mp = String(line[onRange.upperBound..<parenRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard dev.hasPrefix("/dev/"), mp.hasPrefix("/") else { continue }
            mounts.append(EngineMount(devicePath: dev, mountPoint: mp))
        }
        return mounts
    }

    /// Unmount and wait for the microVM to exit. Unprivileged - the engine
    /// tears down the VM it started, so ejecting never needs a password.
    @discardableResult
    static func unmount(mountPoint: String) -> (ok: Bool, message: String) {
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
            return (false, "The drive is in use. Close any open files or apps using it, then try again.")
        }
        return (false, combined.isEmpty ? "The drive could not be ejected." : combined)
    }
}

/// A logical volume discovered inside an unlocked container.
struct LogicalVolume: Equatable {
    let identifier: String   // "lukottavg:disk4s1:root"
    let label: String        // filesystem label, or the LV name
    let filesystem: String   // ext4, btrfs, xfs …
    let size: String

    /// What `anylinuxfs mount` expects for this volume.
    var mountIdentifier: String { "lvm:\(identifier)" }
}

/// Parses `anylinuxfs list --decrypt` output.
///
/// Ubuntu, Debian, Mint, Pop and Fedora all put LVM inside the LUKS container,
/// so unlocking exposes a volume group rather than a filesystem. The engine
/// addresses those as `lvm:<vg>:<disk>:<lv>`, and prints exactly that triple in
/// the IDENTIFIER column:
///
///     lvm:lukottavg (volume group):
///        #:            TYPE NAME             SIZE       IDENTIFIER
///        0:     LVM2_scheme                  +0.6 GB    lukottavg
///                          Physical Store luks-lvm.img
///        1:           btrfs LUKOTTATEST      608.2 MB   lukottavg:luks-lvm.img:data
enum VolumeGroupParser {
    /// Container types that are not themselves mountable.
    private static let containers: Set<String> = [
        "LVM2_scheme", "LVM2_member", "crypto_LUKS", "GUID_partition_scheme",
        "linux_raid_member", "swap",
    ]

    static func logicalVolumes(in text: String) -> [LogicalVolume] {
        var found: [LogicalVolume] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // A mountable row ends in vg:disk:lv and begins with an index.
            guard let identifier = fields.last,
                  identifier.split(separator: ":").count == 3,
                  let first = fields.first, first.hasSuffix(":"),
                  Int(first.dropLast()) != nil,
                  fields.count >= 4
            else { continue }

            let filesystem = fields[1]
            guard !containers.contains(filesystem) else { continue }

            // NAME may be absent when the filesystem carries no label.
            let sizeIndex = fields.count - 3
            let label = fields.count >= 5 ? fields[2] : ""
            let size = "\(fields[sizeIndex]) \(fields[sizeIndex + 1])"
            let lvName = identifier.split(separator: ":").last.map(String.init) ?? identifier
            found.append(LogicalVolume(identifier: identifier,
                                       label: label.isEmpty ? lvName : label,
                                       filesystem: filesystem,
                                       size: size))
        }
        return found
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

        // The engine defaults to a 1 vCPU / 512 MiB microVM, which throttles the
        // in-guest NFS server and filesystem drivers. LUKS decryption needs at
        // least 2560 MiB or the engine raises it itself and warns.
        let cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let ram = 2560

        // macOS negotiates 32 KiB NFS transfers by default; it supports 1 MiB,
        // which matters for sequential throughput on this loopback mount.
        let nfsOptions = "rsize=1048576,wsize=1048576,readahead=128"

        // Which filesystem drivers to try, in order.
        //
        // ntfs3 is the in-kernel driver and much faster, but it refuses a
        // "dirty" volume — which is what Windows Fast Startup and hibernation
        // leave behind, and therefore the most common real-world failure.
        // ntfs-3g will mount those. A Linux volume gets no override at all:
        // the engine detects ext4/btrfs/xfs itself.
        let drivers: [String?]
        switch drive.kind {
        case .microsoft: drivers = ["ntfs3", "ntfs-3g"]
        case .linux:     drivers = [nil]
        }

        let engineQ = shellQuoted(engine.path)
        let deviceQ = shellQuoted(drive.devicePath)
        let logQ = shellQuoted(log.path)
        let listLog = workspace.root.appendingPathComponent("discover.log")

        var attempts = drivers.map { driver -> String in
            let typeFlag = driver.map { " -t \($0)" } ?? ""
            return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount --ignore-permissions"
                + "\(typeFlag) -w false -n \(shellQuoted(nfsOptions)) \(deviceQ) >> \(logQ) 2>&1"
        }

        // A Linux container usually holds LVM rather than a filesystem: Ubuntu,
        // Debian, Mint, Pop and Fedora all layer it that way. `list --decrypt`
        // exposes the volume group, but prompts on a terminal and ignores
        // ALFS_PASSPHRASE, so it is driven through expect with the credential
        // passed in the environment rather than written anywhere.
        if drive.kind == .linux {
            attempts.append("""
            {
              ALFS_PASSPHRASE="$__cred" /usr/bin/expect -c '
                set timeout 600
                spawn -noecho [lindex $argv 0] list --decrypt=all [lindex $argv 1]
                expect { -re "passphrase.*: " { send "$env(ALFS_PASSPHRASE)\r"; exp_continue } eof }
              ' \(engineQ) \(deviceQ) > \(shellQuoted(listLog.path)) 2>&1
              cat \(shellQuoted(listLog.path)) >> \(logQ)
              __lvs=$(awk '$NF ~ /^[^:]+:[^:]+:[^:]+$/ && $2 != "LVM2_scheme" { print $NF }' \(shellQuoted(listLog.path)))
              __count=$(printf '%s\\n' "$__lvs" | grep -c . )
              if [ "$__count" -eq 1 ]; then
                ALFS_PASSPHRASE="$__cred" \(engineQ) mount --ignore-permissions -w false \\
                  -n \(shellQuoted(nfsOptions)) "lvm:$__lvs" >> \(logQ) 2>&1
              elif [ "$__count" -gt 1 ]; then
                echo "LUKOTTA_MULTIPLE_VOLUMES" >> \(logQ)
                false
              else
                false
              fi
            }
            """)
        }

        // One script, one authorisation. Written to the private workspace rather
        // than inlined, because quoting this through AppleScript would be a
        // correctness hazard. It contains no secret: the credential is read
        // from the pipe at run time.
        let script = """
        #!/bin/sh
        \(parts.joined(separator: "\n"))
        __cred="$(cat \(shellQuoted(fifo.path)))"
        \(engineQ) config -n \(cores) -r \(ram) >/dev/null 2>&1 || true
        \(attempts.joined(separator: " || "))
        __rc=$?
        unset __cred
        exit $__rc
        """
        let scriptURL = workspace.root.appendingPathComponent("mount.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: scriptURL.path)

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = [
            "-e", "with timeout of 1800 seconds",
            "-e", "do shell script \(appleScriptQuoted("/bin/sh " + shellQuoted(scriptURL.path))) with administrator privileges",
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

    /// Ask the engine where the volume landed; fall back to scraping only if it
    /// has nothing to say.
    static func discoverMountPoint(for drive: Drive, transcript: String) -> String? {
        if let m = EngineStatus.current().first(where: { $0.devicePath == drive.devicePath }) {
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

/// Turns raw engine output into one plain sentence, without hiding the original.
enum Diagnosis {
    static func summarise(_ transcript: String, fallback: String) -> String {
        let lower = transcript.lowercased()
        if lower.contains("cannot probe") || lower.contains("insufficient permissions") {
            return "macOS blocked access to the drive. Lukotta needs Full Disk Access before it can read an encrypted disk."
        }
        if lower.contains("wrong key") || lower.contains("invalid passphrase")
            || lower.contains("no key available") || lower.contains("keyslot") {
            return "That password or recovery key did not unlock this drive."
        }
        if lower.contains("not a valid bitlocker") || lower.contains("no bitlocker") {
            return "This partition is not a BitLocker volume."
        }
        if lower.contains("hiberfile") || lower.contains("hibernated")
            || lower.contains("unclean") || lower.contains("dirty") {
            return "The drive was not shut down cleanly by Windows. Turn off Fast Startup in Windows, or shut Windows down fully rather than hibernating, then try again."
        }
        if lower.contains("unknown filesystem type") || lower.contains("no such device") {
            return "The engine did not recognise a filesystem on this volume. If it is encrypted, the password or recovery key may be wrong."
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
