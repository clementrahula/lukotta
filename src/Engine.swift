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
            .appendingPathComponent("Library/Application Support/BitLocker Mounter/runtime", isDirectory: true)
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

/// A private, self-destructing working directory.
///
/// anylinuxfs derives every path it uses - the Linux rootfs, its logs, its
/// runtime state - from $HOME. Pointing $HOME here is what keeps the app from
/// writing into the real home directory.
final class Workspace {
    let root: URL
    private var destroyed = false

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("BitLockerMounter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    var homeDirectory: URL { root }

    var alpineDirectory: URL {
        root.appendingPathComponent(".anylinuxfs/alpine", isDirectory: true)
    }

    /// True once the Linux environment is in place for this session.
    var rootfsIsReady: Bool {
        FileManager.default.fileExists(
            atPath: alpineDirectory.appendingPathComponent("rootfs").path)
    }

    /// Put the Linux environment where the engine expects it, inside this
    /// session's workspace so that nothing lands in the real home directory.
    ///
    /// The embedded copy is an archive and is unpacked; a development install is
    /// an existing directory and is symlinked.
    func prepareRootfs(progress: (String) -> Void) throws {
        // Unpacking costs a few seconds; do it once per session, not per retry.
        if rootfsIsReady { return }
        let fm = FileManager.default
        try fm.createDirectory(at: alpineDirectory, withIntermediateDirectories: true)

        // Image metadata first - small files the engine reads alongside the rootfs.
        if let meta = EnginePaths.embeddedAlpineDirectory,
           let entries = try? fm.contentsOfDirectory(atPath: meta.path) {
            for entry in entries where entry != "rootfs.tar.gz" {
                try? fm.copyItem(at: meta.appendingPathComponent(entry),
                                 to: alpineDirectory.appendingPathComponent(entry))
            }
        }

        if let archive = EnginePaths.embeddedRootfsArchive {
            progress("Preparing the Linux environment…")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzpf", archive.path, "-C", alpineDirectory.path]
            let err = Pipe()
            tar.standardError = err
            try tar.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0, rootfsIsReady else {
                let msg = String(data: errData, encoding: .utf8) ?? ""
                throw EngineError.workspace("Could not unpack the Linux environment. \(msg)")
            }
            return
        }

        // Development fallback: reuse an already-initialised rootfs in the home
        // directory rather than copying ~95 MB.
        guard let existing = EnginePaths.developmentRootfs else {
            throw EngineError.missingRootfs
        }
        let dest = alpineDirectory.appendingPathComponent("rootfs")
        try? fm.removeItem(at: dest)
        try fm.createSymbolicLink(at: dest, withDestinationURL: existing)
        let ver = existing.deletingLastPathComponent().appendingPathComponent("rootfs.ver")
        if fm.fileExists(atPath: ver.path) {
            try? fm.copyItem(at: ver, to: alpineDirectory.appendingPathComponent("rootfs.ver"))
        }
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
            return "This copy of BitLocker Mounter is incomplete - its mounting engine is missing."
        case .missingRootfs:
            return "This copy of BitLocker Mounter is incomplete - its Linux environment is missing."
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
