import Foundation
import AppKit

/// Everything the app needs to talk to the anylinuxfs runtime.
///
/// The engine is shipped inside the app bundle. Nothing is downloaded at first
/// run and nothing is installed into the user's home directory: the runtime is
/// pointed at a private working directory under the system temp area, which is
/// removed when the app quits.
enum EnginePaths {
    /// Embedded engine inside the bundle: Resources/engine/...
    static var embeddedEngineRoot: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let root = res.appendingPathComponent("engine", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// Development fallback: the runtime installed by the legacy bootstrap.
    /// Only used when the app has not been packaged with an embedded engine.
    static var developmentEngineRoot: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library/Application Support/Lukotta/runtime", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    static var engineRoot: URL? { embeddedEngineRoot ?? developmentEngineRoot }

    static var anylinuxfs: URL? {
        engineRoot?.appendingPathComponent("anylinuxfs/bin/anylinuxfs")
    }

    /// Directories holding the bundled dylibs. The embedded engine loads its one
    /// external dependency through @executable_path, so this is belt-and-braces
    /// for the development fallback, where the Homebrew layout is still in use.
    static func libraryPaths() -> [String] {
        guard let root = engineRoot else { return [] }
        var out: [String] = []
        let bundled = root.appendingPathComponent("anylinuxfs/lib", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) { out.append(bundled.path) }
        let deps = root.appendingPathComponent("deps", isDirectory: true)
        if let e = FileManager.default.enumerator(at: deps,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.lastPathComponent == "lib" {
                out.append(url.path)
            }
        }
        return out
    }

    /// The recovery-key / password validator shipped in Resources.
    static var validator: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helpers/validate-key.sh")
    }

    /// Rootfs archive that ships with the app, if present.
    static var embeddedRootfsArchive: URL? {
        guard let a = engineRoot?.appendingPathComponent("alpine/rootfs.tar.gz"),
              FileManager.default.fileExists(atPath: a.path) else { return nil }
        return a
    }

    /// Image metadata that sits beside the rootfs.
    static var embeddedAlpineDirectory: URL? {
        guard let d = engineRoot?.appendingPathComponent("alpine", isDirectory: true),
              FileManager.default.fileExists(atPath: d.path) else { return nil }
        return d
    }

    /// Rootfs produced by a previous `anylinuxfs init` in the real home.
    static var developmentRootfs: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".anylinuxfs/alpine/rootfs", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }
}

/// A private, self-destructing working directory for one unlock attempt.
///
/// It holds only the credential pipe and this attempt's mount log. The engine
/// resolves its own working directory from the invoking user's password-database
/// entry rather than from $HOME, so its rootfs and logs cannot be redirected
/// here; see EngineEnvironment.
final class Workspace {
    let root: URL
    private var destroyed = false

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("Lukotta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Create a FIFO used to hand the credential to the elevated process.
    /// The credential never reaches a command line, an environment we export,
    /// or a file on disk.
    func makeCredentialPipe() throws -> URL {
        let fifo = root.appendingPathComponent("credential.fifo")
        try? FileManager.default.removeItem(at: fifo)
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw EngineError.workspace("Could not create the credential pipe (errno \(errno)).")
        }
        return fifo
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
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
enum EngineEnvironment {
    static var alpineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anylinuxfs/alpine", isDirectory: true)
    }

    static var isReady: Bool {
        FileManager.default.fileExists(
            atPath: alpineDirectory.appendingPathComponent("rootfs").path)
    }

    /// Unpack the bundled Linux environment if it is not already in place.
    /// Returns true when work was done, so the caller can explain the delay.
    @discardableResult
    static func prepare(progress: (String) -> Void) throws -> Bool {
        if isReady { return false }
        guard let archive = EnginePaths.embeddedRootfsArchive else {
            throw EngineError.missingRootfs
        }
        let fm = FileManager.default
        try fm.createDirectory(at: alpineDirectory, withIntermediateDirectories: true)

        // Metadata the engine reads alongside the rootfs.
        if let meta = EnginePaths.embeddedAlpineDirectory,
           let entries = try? fm.contentsOfDirectory(atPath: meta.path) {
            for entry in entries where entry != "rootfs.tar.gz" {
                let dest = alpineDirectory.appendingPathComponent(entry)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: meta.appendingPathComponent(entry), to: dest)
                }
            }
        }

        progress("Setting up the Linux environment (first run only)…")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzpf", archive.path, "-C", alpineDirectory.path]
        let err = Pipe()
        tar.standardError = err
        try tar.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, isReady else {
            throw EngineError.workspace(
                "Could not unpack the Linux environment. "
                + (String(data: errData, encoding: .utf8) ?? ""))
        }
        return true
    }
}

enum EngineError: LocalizedError {
    case missingEngine
    case missingRootfs
    case workspace(String)
    case credentialRejected(String)
    case authorisationCancelled
    case mountFailed(summary: String, detail: String)

    var errorDescription: String? {
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
    var detail: String? {
        if case .mountFailed(_, let detail) = self { return detail }
        return nil
    }
}


/// macOS blocks raw reads of /dev/disk* even for root unless the responsible
/// application holds Full Disk Access. There is no public API to query that, so
/// probe a file that only an FDA-holding process can open.
enum Permissions {
    /// Whether macOS refused the engine raw disk access.
    static func isAccessDenied(_ transcript: String) -> Bool {
        let l = transcript.lowercased()
        return l.contains("cannot probe") || l.contains("insufficient permissions")
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
