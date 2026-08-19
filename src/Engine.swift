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

    /// Directories holding the privately relocated dylibs.
    static func libraryPaths() -> [String] {
        guard let deps = engineRoot?.appendingPathComponent("deps", isDirectory: true),
              let e = FileManager.default.enumerator(at: deps,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])
        else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.lastPathComponent == "lib" {
            out.append(url.path)
        }
        return out
    }

    /// The recovery-key / password validator shipped in Resources.
    static var validator: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helpers/validate-key.sh")
    }

    /// Rootfs that ships with the app, if present.
    static var embeddedRootfs: URL? {
        guard let root = engineRoot?.appendingPathComponent("rootfs", isDirectory: true),
              FileManager.default.fileExists(atPath: root.path) else { return nil }
        return root
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

    /// Link the read-only rootfs into $HOME/.anylinuxfs/alpine/rootfs so the
    /// engine finds it without us copying ~90 MB on every launch.
    func linkRootfs(from source: URL) throws {
        let alpine = root.appendingPathComponent(".anylinuxfs/alpine", isDirectory: true)
        try FileManager.default.createDirectory(at: alpine, withIntermediateDirectories: true)
        let dest = alpine.appendingPathComponent("rootfs")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: source)

        // The version marker sits next to the rootfs; copy it when present so the
        // engine does not decide the environment needs reinitialising.
        let verName = "rootfs.ver"
        let srcVer = source.deletingLastPathComponent().appendingPathComponent(verName)
        if FileManager.default.fileExists(atPath: srcVer.path) {
            try? FileManager.default.copyItem(at: srcVer, to: alpine.appendingPathComponent(verName))
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
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/CloudTabs.db",
        ]
        for rel in probes {
            let path = home.appendingPathComponent(rel).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let fh = FileHandle(forReadingAtPath: path) {
                try? fh.close()
                return true
            }
            return false
        }
        // Nothing to probe with: do not block the user on a guess.
        return true
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
