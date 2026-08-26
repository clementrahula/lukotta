// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import Foundation
import SQLite3

/// Everything the app needs to talk to the anylinuxfs runtime.
///
/// The engine is shipped inside the app bundle. Nothing is downloaded at first
/// run and nothing is installed into the home directory: the runtime is pointed
/// at a private working directory under the system temp area, which is removed
/// when the app quits.
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

    /// Which patches the shipped engine was built with.
    ///
    /// The engine is normally the checksummed upstream bottle. Two of its
    /// binaries can instead be built from the same pinned source with the
    /// patches in `patches/` applied, and `vendor-engine.sh` records which.
    /// The application reads that record rather than assuming. A build made
    /// without the patches is fully functional, but opens fewer formats.
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
    /// All three drivers are written for imago and compiled into the engine
    /// here. Without them a fixed VHD still opens, being the raw disk with a
    /// footer after it, while a dynamic VHD, a VDI and a VHDX cannot be read at
    /// all.
    public static var opensVdiAndVhd: Bool {
        enginePatches.contains("imago-vdi-vhd-and-vhdx")
    }

    /// Whether the engine can read a sparse VMDK.
    ///
    /// Upstream's VMDK driver reads the flat form only and refuses the sparse
    /// one by name. The driver built in here reads both.
    public static var opensSparseVmdk: Bool {
        enginePatches.contains("imago-sparse-vmdk")
    }

    /// Directories holding the bundled dylibs. The engine loads its one external
    /// dependency through @executable_path, so this is a second line of
    /// defence.
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
/// It holds the credential pipe and this attempt's mount log. The engine
/// resolves its own working directory from the invoking user's password-database
/// entry rather than from $HOME, so its rootfs and logs cannot be redirected
/// here. See EngineEnvironment.
/// Unchecked and safe. The directory is decided once and does not change, so
/// the only mutable state is whether it has been removed, which is behind a
/// lock. The lock is required because the mount runs on a background task
/// holding this while quitting removes it from the main actor.
public final class Workspace: @unchecked Sendable {
    /// What this copy of the app calls its scratch directories.
    public static let prefix: String = {
        let identifier = Bundle.main.bundleIdentifier ?? "com.lukotta"
        return "Lukotta-\(identifier)-"
    }()

    public let root: URL
    private let lock = NSLock()
    private var destroyed = false

    public init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // Named after this copy of the app, so that a released app and a
        // pre-release sweeping the same temporary directory each take away
        // their own and leave the other's alone.
        root = base.appendingPathComponent(
            "\(Workspace.prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// A symlink to the device, named after the drive.
    ///
    /// Finder labels a network mount with its server name, which the engine
    /// builds from the last component of the path it is handed. Pointing it at a
    /// named link stops the drive appearing as "disk4s1.local".
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
/// This app's own, and nobody else's.
///
/// The engine as published keeps everything under ~/.anylinuxfs, which is right
/// for a copy somebody installed themselves and wrong for one carried inside an
/// application: a release, a beta, and anylinuxfs installed on its own would
/// share one directory and one image, each replacing the version the others
/// were built against. The engine this app ships is patched to take that
/// directory from ANYLINUXFS_HOME (see patches/anylinuxfs-private-home.patch),
/// and this is what it is given -- inside this app's own Application Support
/// directory, which is named after the bundle, so a beta and a release are as
/// separate as two different applications.
///
/// Nothing outside this app writes here, and this app writes nowhere else.
public enum EngineEnvironment {

    /// Where this app kept the engine before the directory was named after the
    /// identifier rather than the file. Left behind by a rename otherwise.
    public static var legacyNamedHome: URL? {
        let name = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != appDirectoryName else { return nil }
        return engineHome(
            inHome: FileManager.default.homeDirectoryForCurrentUser.path, named: name)
    }

    /// Where the engine keeps everything: the image, its configuration, its
    /// logs. Handed to it in the environment of every process that runs it.
    /// The application's own name, which is what its directory is called: a
    /// beta and a release are two applications and keep two directories.
    public static var appDirectoryName: String {
        // The identifier, not the name of the file. Somebody renaming the app
        // in Finder would otherwise be given a fresh directory, a fresh
        // hundred-megabyte unpack, and no sight of the copy kept aside for
        // putting a bad update back. The shim in front of the app reads the
        // same value out of Info.plist, so both arrive at one directory.
        directoryName(
            identifier: Bundle.main.bundleIdentifier,
            fileName: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
    }

    /// The identifier, with the daemon's suffix taken off.
    ///
    /// The privileged helper carries its own Info.plist inside its binary --
    /// SMJobBless requires one -- and an embedded plist wins over the bundle
    /// the executable sits in. So the helper reads `<app>.helper` here where
    /// the app reads `<app>`, and the two compose different directories.
    ///
    /// They must compose the same one. The helper mounts on the app's behalf
    /// and hands the engine `ANYLINUXFS_HOME`: disagreeing, it unpacks a second
    /// Linux environment beside the app's, serves drives from that, and writes
    /// its logs where nothing looks for them. The first drive opened through
    /// the daemon after this diverged failed with "Failed to create log file"
    /// and nothing to say why.
    public static func directoryName(identifier: String?, fileName: String) -> String {
        if let identifier, !identifier.isEmpty {
            return HelperInfo.identifierOfTheApp(behind: identifier)
        }
        return fileName.isEmpty || fileName == "/" ? "Lukotta" : fileName
    }

    /// The engine's directory inside a given home.
    ///
    /// Separate from `engineHome` because the helper runs as root and mounts on
    /// somebody else's behalf: it composes this against their home rather than
    /// root's, and has to arrive at exactly the same path as the app -- or a
    /// mount made through the helper reads a different Linux environment from
    /// one made without it.
    public static func engineHome(inHome home: String, named name: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("engine", isDirectory: true)
    }

    public static var engineHome: URL {
        engineHome(
            inHome: FileManager.default.homeDirectoryForCurrentUser.path,
            named: appDirectoryName)
    }

    /// The name of the variable the patched engine reads.
    public static let homeVariable = "ANYLINUXFS_HOME"

    /// The directories the engine expects to find under its home.
    ///
    /// It writes its logs into Library/Logs and does not create that itself on
    /// macOS -- under a real home it has always been there. Made by the app,
    /// which runs as the person using it, so what the engine writes there
    /// belongs to them and not to root.
    @discardableResult
    public static func makeHomeReady() -> Bool {
        makeHomeReady(at: engineHome)
    }

    /// The same, for a home somebody else composed.
    ///
    /// The engine creates whatever `ANYLINUXFS_HOME` names, and then opens its
    /// log inside `Library/Logs` of it -- which on macOS it does not create.
    /// So a home that exists is not a home that works, and "Failed to create
    /// log file: No such file or directory" is the whole of what the engine
    /// says about the difference: nothing about which directory, and nothing
    /// about it having been almost right.
    ///
    /// Every route composes this path for itself -- the app for its own runs,
    /// the daemon for the user it mounts on behalf of -- so making the log
    /// directory belongs to the home, not to whichever caller remembered.
    @discardableResult
    public static func makeHomeReady(at home: URL) -> Bool {
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        return
            (try? FileManager.default.createDirectory(
                at: logs, withIntermediateDirectories: true)) != nil
    }

    /// The environment every run of the engine is given.
    ///
    /// One place, because an engine run without it looks at the shared home
    /// instead -- which is a different image, possibly somebody else's, and a
    /// mount that then fails for reasons nothing on this side can explain.
    public static func environmentForEngine(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        makeHomeReady()
        var environment = base
        environment[homeVariable] = engineHome.path
        return environment
    }

    public static var alpineDirectory: URL {
        engineHome.appendingPathComponent(".anylinuxfs/alpine", isDirectory: true)
    }

    public static var isReady: Bool { isReady(in: alpineDirectory) }

    public static func isReady(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("rootfs").path)
    }

    /// Which Linux environment is unpacked, and which one this app carries.
    ///
    /// Written beside the rootfs by the build, and shipped in the bundle. The
    /// file has been there all along and nothing read it: the environment was
    /// unpacked once, on the first run, and never again. So an update that
    /// changed the guest -- a kernel, a filesystem tool, an Alpine security fix
    /// -- reached nobody who already had the app. They kept the environment
    /// from the day they installed it and ran the new engine against it.
    public static func versionOfGuest(in directory: URL) -> String? {
        version(at: directory.appendingPathComponent("rootfs.ver"))
    }

    public static var versionShipped: String? {
        EnginePaths.embeddedAlpineDirectory
            .flatMap { version(at: $0.appendingPathComponent("rootfs.ver")) }
    }

    private static func version(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether what is unpacked is not what this app carries.
    ///
    /// Only when both versions can be read. A guest from before the version
    /// file existed, or a bundle without one, is left exactly as it is: this
    /// replaces a working environment, so it does it on evidence or not at all.
    public static func needsRefresh(in directory: URL, shipped: String? = versionShipped) -> Bool {
        guard isReady(in: directory), let shipped, let have = versionOfGuest(in: directory)
        else { return false }
        return have != shipped
    }

    /// What was there before this app had a directory of its own.
    ///
    /// Every copy installed before then unpacked the Linux environment into the
    /// one the engine shares, ~/.anylinuxfs. Moving it is a rename on the same
    /// filesystem -- instant, and it saves unpacking eighty megabytes again --
    /// but only when it is unmistakably this app's own work: the entry count
    /// and the package list are written by this project's build and by nothing
    /// else, while "anylinuxfs init" leaves an OCI layout, an mtree and a
    /// version. Anything else is left exactly where it is, for whatever put it
    /// there.
    ///
    /// Nothing is said about any of this. It is not the person's problem.
    @discardableResult
    public static func adoptWhatWasLeftInTheSharedHome(
        from shared: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anylinuxfs/alpine", isDirectory: true),
        into directory: URL = alpineDirectory,
        mountTable table: String = LukottaCore.mountTable()
    ) -> Bool {
        let manager = FileManager.default
        guard !isReady(in: directory), isReady(in: shared) else { return false }
        let ours = ["rootfs.count", "removed-packages.txt"].allSatisfy {
            manager.fileExists(atPath: shared.appendingPathComponent($0).path)
        }
        guard ours else { return false }
        // Never out from under a machine that is serving a drive from it.
        guard !MountTableEntry.all(in: table).contains(where: \.isEngineMount) else { return false }
        try? manager.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? manager.moveItem(at: shared, to: directory)) != nil else { return false }
        Log.app.notice("moved this app's Linux environment into its own directory")
        return true
    }

    /// Take away what is left under the old name once nothing of ours is in
    /// it any more.
    ///
    /// The adoption above is a move, so it empties the directory rather than
    /// clearing it: `<Old Name>/engine/.anylinuxfs` and its parents stay behind
    /// as empty directories nobody will ever look in. Removed only while they
    /// are empty -- a Mac that has not been through the move yet keeps
    /// everything it has.
    public static func forgetLegacyNamedHomeIfEmpty() {
        guard let older = legacyNamedHome else { return }
        let manager = FileManager.default
        // engine/, then the directory named after the application, innermost
        // first. Each goes only if the one inside it left nothing behind.
        var here: URL? = older
        while let url = here, url.lastPathComponent != "Application Support" {
            guard let left = try? manager.contentsOfDirectory(atPath: url.path) else { return }
            let real = left.filter { $0 != ".DS_Store" }
            guard real.isEmpty else { return }
            try? manager.removeItem(at: url)
            here = url.deletingLastPathComponent()
        }
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
        // A directory half-unpacked by a run that was interrupted -- a crash, a
        // forced quit, a Mac going to sleep -- has a rootfs in it and no
        // version file, so it would be taken for ready and never repaired.
        // Unpacking happens beside the real one and is moved into place at the
        // end, so what is there is either complete or not there at all.
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".unpacking", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)

        // The home this unpack is for, which is not always this process's own:
        // the daemon prepares the home of the user it mounts on behalf of, and
        // `directory` is `<that home>/.anylinuxfs/alpine`.
        makeHomeReady(at: directory.deletingLastPathComponent().deletingLastPathComponent())
        makeHomeReady()

        // An environment this app unpacked before it had a directory of its
        // own is moved across rather than unpacked again -- and so is one it
        // left under the app's file name, before the directory was named after
        // the identifier instead. Both are this app's own work; neither is
        // worth eighty megabytes of unpacking to arrive at again.
        if directory == alpineDirectory {
            adoptWhatWasLeftInTheSharedHome(into: directory)
            if let older = legacyNamedHome {
                adoptWhatWasLeftInTheSharedHome(
                    from: older.appendingPathComponent(".anylinuxfs/alpine", isDirectory: true),
                    into: directory)
            }
        }

        if isReady(in: directory) {
            guard needsRefresh(in: directory) else { return false }
            // The environment is replaced, not merged: files the last version
            // had and this one does not would otherwise stay for ever. Only
            // while nothing is being served from it -- a running machine reads
            // this filesystem, and the engine takes an exclusive lock to write
            // here for exactly that reason. Left for the next launch otherwise,
            // which is where the old environment goes on working meanwhile.
            guard !MountTableEntry.all(in: mountTable()).contains(where: \.isEngineMount) else {
                Log.app.notice("the Linux environment is out of date; a drive is open, so later")
                return false
            }
            Log.app.notice(
                "replacing the Linux environment: \(versionOfGuest(in: directory) ?? "unknown", privacy: .public) -> \(versionShipped ?? "unknown", privacy: .public)"
            )
            // The whole environment, not just the rootfs: the image metadata
            // beside it -- config.json, the OCI layout, the mtree -- describes
            // that rootfs and not this one. Taken away only once the new one
            // has been unpacked, below.
        }
        guard let archive = source ?? EnginePaths.embeddedRootfsArchive else {
            throw EngineError.missingRootfs
        }
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Metadata the engine reads alongside the rootfs.
        if let meta = EnginePaths.embeddedAlpineDirectory,
            let entries = try? fm.contentsOfDirectory(atPath: meta.path)
        {
            for entry in entries where entry != "rootfs.tar.gz" {
                try? fm.copyItem(
                    at: meta.appendingPathComponent(entry),
                    to: staging.appendingPathComponent(entry))
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

        // Not the shared runner: this reads stderr as it arrives to count
        // entries for the progress, rather than collecting output at the end.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzpvf", archive.path, "-C", staging.path]
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
        guard tar.terminationStatus == 0, isReady(in: staging) else {
            try? fm.removeItem(at: staging)
            throw EngineError.workspace(
                "Could not unpack the Linux environment. "
                    + lastLines.joined(separator: " "))
        }

        // The one moment the old environment stops existing and the new one
        // starts, with nothing in between that could be taken for either.
        try? fm.removeItem(at: directory)
        do {
            try fm.moveItem(at: staging, to: directory)
        } catch {
            try? fm.removeItem(at: staging)
            throw EngineError.workspace(
                "Could not put the Linux environment in place. \(error.localizedDescription)")
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
        // The name is read from the bundle: an unbranded build is not called
        // Lukotta, and telling somebody their copy of another name is
        // incomplete is worse than saying nothing.
        case .missingEngine:
            return appString(
                "This copy of \(appName) is incomplete: its drive engine is missing. Install it again."
            )
        case .missingRootfs:
            return appString(
                "This copy of \(appName) is incomplete: its Linux environment is missing. Install it again."
            )
        case .workspace(let why):
            return why
        case .credentialRejected(let why):
            return why
        case .authorisationCancelled:
            return appString(
                "You cancelled the administrator prompt, so the drive was not opened.")
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
        for path in [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            home.appendingPathComponent("Library/Safari/CloudTabs.db").path,
            // The system's own, which every macOS install has whether or not
            // this account has ever been asked for a permission. Without it,
            // an account with neither of the two above — a fresh one, or one
            // that has never opened Safari — had nothing to probe, and access
            // was assumed granted: the permission screen was skipped and the
            // first mount failed instead of the app saying so beforehand.
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let fh = FileHandle(forReadingAtPath: path) else { return false }
            try? fh.close()
            return true
        }
        // Nothing to probe with at all, which means macOS has changed where it
        // keeps these. Do not block on a guess.
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
        let reading = Reading(
            fullDiskAccess: hasFullDiskAccess,
            removableVolumes: removableVolumeAccess())
        wasGranted = reading.fullDiskAccess
        return reading
    }

    /// What the permission was the last time anybody looked.
    ///
    /// Reading it for real opens files, which is why it is done off the main
    /// thread -- and that is a whole screen too late to decide which screen to
    /// draw first. The app used to open on the drive list and replace it with
    /// the permission screen a moment later, so the first thing anybody saw on
    /// a new install was a flicker of a list they cannot have.
    ///
    /// So the answer is remembered. There is no record on a Mac that has never
    /// run this app, and no Mac has this permission before it is granted by
    /// hand, so the honest first answer is no.
    public static var wasGranted: Bool {
        get { UserDefaults.standard.bool(forKey: grantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: grantedKey) }
    }

    /// Which screen to open on, answered before the first frame is drawn.
    ///
    /// Granted last time is enough on its own: the permission is not taken away
    /// while the app is closed without somebody going to System Settings to do
    /// it, and the reading that follows a moment later catches that.
    ///
    /// Not granted last time is where the flicker was. Granting Full Disk
    /// Access makes macOS quit the app, so the very next launch is the one
    /// where the record is stale -- and opening on the permission screen and
    /// replacing it half a second later is what somebody sees immediately after
    /// doing what the permission screen asked. So that case, and only that
    /// case, is worth one look at the disk here: a file that exists and an open
    /// that fails at once when the permission is missing.
    public static func likelyGranted() -> Bool {
        if wasGranted { return true }
        let granted = hasFullDiskAccess
        wasGranted = granted
        return granted
    }

    public static let grantedKey = "fullDiskAccessWasGranted"

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

        // The shape of this database is nobody's documented interface, and it
        // has changed before: the column was called allowed until macOS 10.15.
        // Renamed again, the query below would fail and read as "not granted"
        // rather than as "cannot tell", and the app would go on asking for a
        // permission that had already been given. So the columns are checked
        // first, and anything unexpected is reported as not knowing.
        guard hasTheExpectedShape(handle) else {
            Log.app.notice("the TCC database is not the shape this expects; not reading it")
            return nil
        }

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

    /// Whether the access table still has the three columns this reads.
    private static func hasTheExpectedShape(_ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "pragma table_info(access)", -1, &statement, nil)
                == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns.isSuperset(of: ["service", "client", "auth_value"])
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
