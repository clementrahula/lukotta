// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The processes the engine starts beside the virtual machine, and how to be
/// rid of the ones nothing is using.
///
/// A mount that succeeds leaves `gvproxy` running: it carries the network the
/// NFS connection is made over, and ejecting takes it down with the machine. A
/// mount that fails leaves it running too, with nothing to take it down, since
/// the engine records only mounts it completed. Left alone they accumulate, one
/// per failed attempt, and the next attempt then finds the image file locked by
/// one of them.
///
/// The remedy here is deliberately narrow: only processes started from this
/// bundle's own engine, and only ones that appeared during an attempt that then
/// failed. Nothing belonging to another copy of the app, to the user, or to a
/// mount that is still serving a drive is touched.
public enum EngineProcesses {

    /// The engine helpers running right now, by process identifier.
    ///
    /// Matched on the path they were started from, which is inside the running
    /// bundle. A second copy of the app, or the engine installed by Homebrew,
    /// runs from a different path and is left alone.
    public static func running() -> Set<Int32> {
        guard let engine = EnginePaths.anylinuxfs else { return [] }
        let directory = engine.deletingLastPathComponent().deletingLastPathComponent().path

        guard let result = run("/bin/ps", ["-axo", "pid=,args="]) else { return [] }

        var found: Set<Int32> = []
        for line in result.out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let arguments = String(trimmed[space...])
            guard arguments.contains(directory) else { continue }
            found.insert(pid)
        }
        return found
    }

    /// End the helpers in `pids`, having asked first.
    ///
    /// `SIGTERM` lets gvproxy remove its own sockets. The second signal is for
    /// one that does not answer, since a helper left running is the whole
    /// problem this exists to solve.
    public static func stop(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        // Long enough for an orderly exit and short enough not to hold up the
        // failure the user is waiting to be told about.
        Thread.sleep(forTimeInterval: 0.5)
        let stillThere = running()
        for pid in pids where stillThere.contains(pid) { kill(pid, SIGKILL) }
    }

    /// Take down whatever an attempt started, given the helpers that were
    /// running before it began.
    ///
    /// Called when the attempt failed. A helper that was already there belongs
    /// to a drive somebody has open and is left running.
    public static func stopWhatStartedSince(_ before: Set<Int32>) {
        stop(running().subtracting(before))
    }

    /// Take down anything of the engine's that is serving nothing.
    ///
    /// The engine runs one instance at a time, and refuses to start while
    /// another is there: "another instance is already running". A mount that
    /// failed, or one whose eject did not take its machine with it, therefore
    /// stops the next drive from opening at all -- somebody who mistypes a
    /// passphrase is told the engine is busy when they type the right one.
    ///
    /// The evidence used is the system's own mount table rather than the
    /// engine's record of itself, which is what goes stale: with no NFS mount
    /// anywhere on this Mac, nothing the engine is running is serving anything.
    /// Only processes started from this bundle are touched.
    public static func tidyWhatServesNothing(mountTable table: String = LukottaCore.mountTable())
        -> Int
    {
        // A mount whose server has gone is not a drive somebody has open. It
        // sits in the table looking exactly like one, which stopped this sweep
        // before it started and left the leftovers it exists to take down.
        let table = deadMountsCleared(in: table) ? LukottaCore.mountTable() : table
        guard !MountTableEntry.all(in: table).contains(where: \.isEngineMount) else { return 0 }
        let idle = running()
        guard !idle.isEmpty else { return 0 }
        Log.mount.notice("taking down \(idle.count, privacy: .public) engines serving nothing")
        stop(idle)
        return idle.count
    }

    /// The privilege this package does not have, lent by whoever does.
    ///
    /// A mount the engine made as root does not come down for the user who
    /// asked for it, and this package is only ever the user. The app installs
    /// the helper's unmount here at launch; a test binary, an uninstaller or
    /// the helper itself leaves it empty and simply does without. Kept as a
    /// lent function rather than an argument threaded through six call sites,
    /// because the deepest caller is a mount inside this package that knows
    /// nothing of XPC.
    private static let lentLock = NSLock()
    private nonisolated(unsafe) static var lentRootUnmount: ((String) -> Bool)?

    public static func lendRootUnmount(_ unmount: @escaping (String) -> Bool) {
        lentLock.lock()
        defer { lentLock.unlock() }
        lentRootUnmount = unmount
    }

    static func rootUnmount() -> ((String) -> Bool)? {
        lentLock.lock()
        defer { lentLock.unlock() }
        return lentRootUnmount
    }

    /// Whether a mount point is one this app is entitled to force down.
    ///
    /// Two proofs, either of which is enough: this app wrote the mount point
    /// down when it made it, or it is under this user's own `~/Volumes`, where
    /// only an unprivileged mount of theirs can be. Everything else in the
    /// table -- the other channel's drives, a Homebrew anylinuxfs somebody runs
    /// alongside this, an NFS file server that happens to be under /Volumes --
    /// is somebody else's to take down, and a forced unmount of it is data
    /// somebody loses.
    public static func isOursToForce(_ mountPoint: String, opened: Set<String> = OpenedHere.all())
        -> Bool
    {
        if opened.contains(mountPoint) { return true }
        let mine = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true).path
        return mountPoint.hasPrefix(mine + "/")
    }

    /// How a mount answered a probe.
    public enum MountAnswer: Sendable {
        case alive
        case silent
        /// The probe never ran, so this says nothing about the mount.
        case couldNotAsk
    }

    /// Ask one mount whether it is still there.
    public static func mountAnswers(_ point: String, timeout: TimeInterval = 2) -> MountAnswer {
        // stat -f on a child that does not exist rather than on the mount root:
        // the root's attributes can be answered out of the NFS client's cache
        // for up to a minute after the server has gone, so probing it calls a
        // dead mount live exactly when it matters. A lookup of a name the
        // client has never seen has to go to the server.
        let probe = (point as NSString).appendingPathComponent(".lukotta-is-anyone-there")
        switch LukottaCore.ask("/usr/bin/stat", ["-f", "%d", probe], timeout: timeout) {
        // Any answer at all, including "no such file", means a server answered.
        case .finished: return .alive
        case .silent: return .silent
        case .couldNotAsk: return .couldNotAsk
        }
    }

    /// The engine mounts in this table that no longer answer.
    ///
    /// Asked of each mount rather than inferred from which engines are running:
    /// the engine that abandoned a mount is usually still on its way out, and
    /// counting it says the mount is served when it is not.
    ///
    /// The probe is a stat in a process of its own, with two seconds to answer.
    /// A live mount answers at once; one whose server has gone does not, and
    /// the deadline is what stops this waiting on it as everything else does.
    ///
    /// Two silences, a second apart, before a mount is called dead. One is not
    /// evidence: a machine flushing a large copy can miss a two-second deadline
    /// and still be serving somebody's drive perfectly well. And a probe that
    /// could not be started at all -- no descriptors, no processes -- stops the
    /// whole answer, because on a Mac in that state every mount looks dead and
    /// the sweep that follows would take all of them down.
    public static func deadEngineMounts(
        in table: String,
        opened: Set<String> = OpenedHere.all(),
        answers: (String) -> MountAnswer = { mountAnswers($0) },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> [String] {
        let candidates = MountTableEntry.all(in: table).filter(\.isEngineMount).map(\.mountPoint)
            .filter { isOursToForce($0, opened: opened) }
        guard !candidates.isEmpty else { return [] }

        var quiet: [String] = []
        for point in candidates {
            switch answers(point) {
            case .alive: continue
            case .couldNotAsk:
                Log.mount.notice("could not ask whether mounts are still served; leaving them")
                return []
            case .silent: quiet.append(point)
            }
        }
        guard !quiet.isEmpty else { return [] }

        // Asked again, once, after a moment. Only a mount that is silent both
        // times is taken to have lost its server.
        pause(1)
        var dead: [String] = []
        for point in quiet {
            switch answers(point) {
            case .silent: dead.append(point)
            case .alive: continue
            case .couldNotAsk: return []
            }
        }
        return dead
    }

    /// Take away mounts whose server has gone, and say whether any went.
    ///
    /// One left in place makes macOS refuse the next mount at that name --
    /// "invalid file system" -- which the mount script reads as a drive that
    /// will not take writes, so it falls back to read-only and says nothing.
    ///
    /// Forced, because a mount with no server does not come down politely. An
    /// unprivileged mount under `~/Volumes` is this user's to unmount; one the
    /// engine made as root under `/Volumes` is not, and `unmountAsRoot` is how
    /// the caller lends the privilege it already has -- the helper, on the app
    /// side. Without it, a root leftover simply stays, which is honest: saying
    /// something came down when it did not is what sent the sweep on to take
    /// down engines that were still serving it.
    @discardableResult
    public static func deadMountsCleared(
        in table: String,
        unmountAsRoot: ((String) -> Bool)? = nil
    ) -> Bool {
        let unmountAsRoot = unmountAsRoot ?? rootUnmount()
        let dead = deadEngineMounts(in: table)
        guard !dead.isEmpty else { return false }
        Log.mount.notice("taking away \(dead.count, privacy: .public) mounts whose server has gone")
        var went = 0
        for point in dead {
            var cleared = LukottaCore.run("/sbin/umount", ["-f", point], timeout: 20)?.ok == true
            if !cleared, let unmountAsRoot { cleared = unmountAsRoot(point) }
            guard cleared else {
                Log.mount.error("a mount whose server has gone would not come down")
                continue
            }
            went += 1
            // The directory it was mounted on, which is this app's to remove
            // when nothing is on it. rmdir refuses anything else.
            _ = rmdir(point)
        }
        return went > 0
    }

    /// Take down helpers left over from a previous run.
    ///
    /// Only when the engine reports no mounts at all: with nothing mounted,
    /// anything still running is serving nothing. The engine's status covers
    /// every copy of the app, so a drive somebody else has open is enough to
    /// leave all of them alone.
    public static func tidyLeftovers() {
        guard EngineStatus.current().isEmpty else { return }
        let leftovers = running()
        guard !leftovers.isEmpty else { return }
        Log.mount.notice("taking down \(leftovers.count, privacy: .public) leftover helpers")
        stop(leftovers)
    }
}
