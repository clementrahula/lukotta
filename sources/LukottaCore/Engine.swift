import AppKit
import Foundation
import SQLite3

/// Everything the app needs to talk to the anylinuxfs runtime.
///
/// The engine is shipped inside the app bundle. Nothing is downloaded at first
/// run and nothing is installed into the user's home directory: the runtime is
/// pointed at a private working directory under the system temp area, which is
/// removed when the app quits.
public enum EnginePaths {
    /// Embedded engine inside the bundle: Resources/engine/...
    public static var embeddedEngineRoot: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let root = res.appendingPathComponent("engine", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    public static var engineRoot: URL? { embeddedEngineRoot }

    public static var anylinuxfs: URL? {
        engineRoot?.appendingPathComponent("anylinuxfs/bin/anylinuxfs")
    }

    /// Which of our patches the shipped engine was built with.
    ///
    /// The engine is normally the checksummed upstream bottle. Two of its
    /// binaries can instead be built from the same pinned source with the
    /// patches in `patches/`, and `vendor-engine.sh` writes down which — so the
    /// app can say what it can do rather than assume. A build without them
    /// works; it simply cannot open some things.
    public static var enginePatches: Set<String> {
        guard let root = engineRoot?.appendingPathComponent("anylinuxfs/PATCHES"),
            let text = try? String(contentsOf: root, encoding: .utf8)
        else { return [] }
        return Set(
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
    }

    /// Whether the guest unlocks encryption it finds inside an image.
    ///
    /// Without the patch the host probes an image only far enough to know it is
    /// one, so nothing is on the decrypt list and the guest is handed
    /// "crypto_LUKS" as though it were a filesystem.
    public static var opensEncryptionInsideImages: Bool {
        enginePatches.contains("vmproxy-decrypt-what-it-probes")
    }

    /// Whether the engine can read a VDI, a VHD that is not simply raw, and a
    /// VHDX.
    ///
    /// All three drivers are ours, written for imago and built into the engine
    /// here. Without them a fixed VHD still opens — it is the raw disk with a
    /// footer after it — but a dynamic one, every VDI and every VHDX would be
    /// read as gibberish.
    public static var opensVdiAndVhd: Bool {
        enginePatches.contains("imago-vdi-vhd-and-vhdx")
    }

    /// Whether the engine can read a sparse VMDK.
    ///
    /// Upstream's VMDK driver reads the flat form only and refuses the sparse
    /// one by name. The driver ours is built on reads both.
    public static var opensSparseVmdk: Bool {
        enginePatches.contains("imago-sparse-vmdk")
    }

    /// Directories holding the bundled dylibs. The engine loads its one external
    /// dependency through @executable_path, so this is belt-and-braces.
    public static func libraryPaths() -> [String] {
        guard let root = engineRoot else { return [] }
        var out: [String] = []
        let bundled = root.appendingPathComponent("anylinuxfs/lib", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) { out.append(bundled.path) }
        let deps = root.appendingPathComponent("deps", isDirectory: true)
        if let e = FileManager.default.enumerator(
            at: deps,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for case let url as URL in e where url.lastPathComponent == "lib" {
                out.append(url.path)
            }
        }
        return out
    }

    /// The recovery-key / password validator shipped in Resources.
    public static var validator: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helpers/validate-key.sh")
    }

    /// Rootfs archive that ships with the app, if present.
    public static var embeddedRootfsArchive: URL? {
        guard let a = engineRoot?.appendingPathComponent("alpine/rootfs.tar.gz"),
            FileManager.default.fileExists(atPath: a.path)
        else { return nil }
        return a
    }

    /// Image metadata that sits beside the rootfs.
    public static var embeddedAlpineDirectory: URL? {
        guard let d = engineRoot?.appendingPathComponent("alpine", isDirectory: true),
            FileManager.default.fileExists(atPath: d.path)
        else { return nil }
        return d
    }

}

/// A private, self-destructing working directory for one unlock attempt.
///
/// It holds only the credential pipe and this attempt's mount log. The engine
/// resolves its own working directory from the invoking user's password-database
/// entry rather than from $HOME, so its rootfs and logs cannot be redirected
/// here; see EngineEnvironment.
/// Unchecked, and safe: the directory is decided once and never changes, so
/// the only mutable thing here is whether it has been removed yet — and that is
/// behind a lock. It has to be: the mount runs on a background task holding
/// this, while quitting removes it from the main actor.
public final class Workspace: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var destroyed = false

    public init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("Lukotta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// A symlink to the device, named after the drive.
    ///
    /// Finder labels a network mount with its server name, which the engine
    /// builds from the last component of the path it is handed. Pointing it at
    /// a nicely named link is what stops the drive appearing as "disk4s1.local".
    public func makeDeviceAlias(named name: String, target: String) throws -> URL {
        let cleaned =
            name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned.isEmpty ? "Encrypted Drive" : String(cleaned.prefix(40))
        let dir = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(safe)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target)
        return link
    }

    /// Create a FIFO used to hand the credential to the elevated process.
    /// The credential never reaches a command line, an environment we export,
    /// or a file on disk.
    public func makeCredentialPipe() throws -> URL {
        let fifo = root.appendingPathComponent("credential.fifo")
        try? FileManager.default.removeItem(at: fifo)
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw EngineError.workspace("Could not create the credential pipe (errno \(errno)).")
        }
        return fifo
    }

    public func destroy() {
        lock.lock()
        let already = destroyed
        destroyed = true
        lock.unlock()
        guard !already else { return }
        try? FileManager.default.removeItem(at: root)
    }

    deinit { destroy() }
}

/// Makes sure the Linux environment the engine needs is present.
///
/// The engine hard-resolves ~/.anylinuxfs from the invoking user and offers no
/// setting to move it, so the app cannot keep it elsewhere. What it can do is
/// guarantee the environment is there without downloading anything: the rootfs
/// ships inside the bundle and is unpacked on demand.
public enum EngineEnvironment {
    public static var alpineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anylinuxfs/alpine", isDirectory: true)
    }

    public static var isReady: Bool { isReady(in: alpineDirectory) }

    public static func isReady(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("rootfs").path)
    }

    /// How far through the unpacking we are, or nil when there is nothing to
    /// count against.
    ///
    /// Never reaches 100: the last entry out of tar is not the last of the
    /// work, and a bar that sits full while the app is still busy reads as a
    /// hang. The count comes from a file written at build time and can be
    /// wrong, so it is clamped rather than trusted.
    public static func percentage(seen: Int, expected: Int) -> Int? {
        guard expected > 0 else { return nil }
        return min(99, max(0, seen) * 100 / expected)
    }

    /// Unpack the bundled Linux environment if it is not already in place.
    /// Returns true when work was done, so the caller can explain the delay.
    ///
    /// `into` and `from` exist so the unpacking can be exercised against a
    /// small archive in a temporary directory. Left alone, it does what it has
    /// always done.
    @discardableResult
    public static func prepare(
        into directory: URL = alpineDirectory,
        from source: URL? = nil,
        progress: (String) -> Void
    ) throws -> Bool {
        if isReady(in: directory) { return false }
        guard let archive = source ?? EnginePaths.embeddedRootfsArchive else {
            throw EngineError.missingRootfs
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Metadata the engine reads alongside the rootfs.
        if let meta = EnginePaths.embeddedAlpineDirectory,
            let entries = try? fm.contentsOfDirectory(atPath: meta.path)
        {
            for entry in entries where entry != "rootfs.tar.gz" {
                let dest = directory.appendingPathComponent(entry)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: meta.appendingPathComponent(entry), to: dest)
                }
            }
        }

        progress("Setting up the Linux environment (first run only)…")

        // Count entries as they are written so this reports a percentage. It is
        // the longest wait a new user ever sees, and a bare spinner for a couple
        // of minutes is indistinguishable from a hang.
        let expected =
            EnginePaths.embeddedAlpineDirectory
            .flatMap {
                try? String(
                    contentsOf: $0.appendingPathComponent("rootfs.count"),
                    encoding: .utf8)
            }
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzpvf", archive.path, "-C", directory.path]
        let err = Pipe()
        tar.standardError = err
        try tar.run()

        var seen = 0
        var pending = ""
        // tar -v writes the name of every entry to stderr, so whatever went
        // wrong is buried in tens of thousands of filenames. Keep the last few
        // lines: an error is the last thing written before it stops.
        var lastLines: [String] = []
        let handle = err.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending += String(data: chunk, encoding: .utf8) ?? ""
            let lines = pending.components(separatedBy: "\n")
            pending = lines.last ?? ""
            let complete = lines.dropLast()
            seen += complete.count
            lastLines.append(contentsOf: complete)
            if lastLines.count > 5 { lastLines.removeFirst(lastLines.count - 5) }
            if let pct = percentage(seen: seen, expected: expected) {
                progress("Setting up the Linux environment — \(pct)%")
            }
        }
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, isReady(in: directory) else {
            throw EngineError.workspace(
                "Could not unpack the Linux environment. "
                    + lastLines.joined(separator: " "))
        }
        return true
    }
}

public enum EngineError: LocalizedError {
    case missingEngine
    case missingRootfs
    case workspace(String)
    case credentialRejected(String)
    case authorisationCancelled
    case mountFailed(summary: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .missingEngine:
            return "This copy of Lukotta is incomplete - its mounting engine is missing."
        case .missingRootfs:
            return "This copy of Lukotta is incomplete - its Linux environment is missing."
        case .workspace(let why):
            return why
        case .credentialRejected(let why):
            return why
        case .authorisationCancelled:
            return "You cancelled the administrator prompt, so the drive was not opened."
        case .mountFailed(let summary, _):
            return summary
        }
    }

    /// Raw engine output, shown behind a disclosure triangle rather than thrown away.
    public var detail: String? {
        if case .mountFailed(_, let detail) = self { return detail }
        return nil
    }
}

/// macOS blocks raw reads of /dev/disk* even for root unless the responsible
/// application holds Full Disk Access. There is no public API to query that, so
/// probe a file that only an FDA-holding process can open.
public enum Permissions {
    /// Whether Full Disk Access has been granted.
    ///
    /// There is no API to request it — Apple requires it to be switched on by
    /// hand — but it can be *detected*, by reading a file only an FDA-holding
    /// process can open. Detecting it lets the app say so before the user types
    /// a password, instead of failing afterwards.
    public static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rel in [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/CloudTabs.db",
        ] {
            let path = home.appendingPathComponent(rel).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let fh = FileHandle(forReadingAtPath: path) else { return false }
            try? fh.close()
            return true
        }
        // Nothing to probe with: do not block on a guess.
        return true
    }

    /// Whether macOS refused the engine raw disk access.
    public static func isAccessDenied(_ transcript: String) -> Bool {
        let l = transcript.lowercased()
        return l.contains("cannot probe") || l.contains("insufficient permissions")
    }

    /// Both permission probes at once, off whatever thread asks.
    ///
    /// Each opens files — one of them a SQLite database — so together they are
    /// disk I/O, and reading them where the interface is drawn stalls the first
    /// frame on however long the disk takes to answer.
    public struct Reading: Sendable {
        public let fullDiskAccess: Bool
        /// nil when it cannot be determined.
        public let removableVolumes: Bool?
    }

    public static func reading() -> Reading {
        Reading(
            fullDiskAccess: hasFullDiskAccess,
            removableVolumes: removableVolumeAccess())
    }

    /// Whether access to removable volumes has been granted.
    ///
    /// Returns nil when it cannot be determined. macOS offers no API for this,
    /// but the decision is recorded in the user's TCC database, which is
    /// readable once Full Disk Access is held — so in the case that matters,
    /// deciding whether to keep asking, the answer is usually knowable.
    public static func removableVolumeAccess() -> Bool? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }

        // Read in-process. Spawning sqlite3 does not work: the subprocess is
        // judged by TCC on its own, so it cannot read the database even when
        // this application can.
        // Opened immutable through a URI. A plain read-only open fails on this
        // database: SQLite wants to create -wal and -shm sidecars beside it,
        // which is not permitted, and the read then reports nothing rather than
        // the answer that is sitting right there.
        var handle: OpaquePointer?
        let uri = "file:\(db.path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            return nil
        }
        defer { sqlite3_close(handle) }

        let sql = """
            select auth_value from access
            where service = 'kTCCServiceSystemPolicyRemovableVolumes' and client = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(
            statement, 1, identifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0) == 2
    }

    public static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// Removable-volume access lives under Files & Folders.
    public static func openFilesAndFoldersSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        // NSWorkspace is required here: these deep links do not resolve when
        // handed to `open` from a shell.
        NSWorkspace.shared.open(url)
    }
}
