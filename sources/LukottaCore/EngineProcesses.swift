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

    /// The microVMs running right now: the processes that actually serve
    /// mounts, as opposed to the network helper beside them.
    ///
    /// `running()` matches everything started from the engine directory, which
    /// includes gvproxy -- and gvproxy outlives a mount that failed, which is
    /// the whole reason the sweep exists. So it cannot answer "is anything
    /// still serving this drive". A `mount` process can.
    public static func serving() -> Set<Int32> {
        guard let engine = EnginePaths.anylinuxfs else { return [] }
        guard let result = run("/bin/ps", ["-axo", "pid=,args="]) else { return [] }
        var found: Set<Int32> = []
        for line in result.out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let arguments = String(trimmed[space...])
            guard arguments.contains(engine.path), arguments.contains(" mount") else { continue }
            found.insert(pid)
        }
        return found
    }

    /// How long a machine is given to put its writes on the disk before it is
    /// killed outright.
    ///
    /// This used to be a flat half-second sleep followed by `SIGKILL`, and the
    /// half second was a guess. What is on the other side of that guess was
    /// measured, and it is not a stray socket: the engine's disk backend makes
    /// writes durable when it shuts down, not when a write is acknowledged, so
    /// a machine killed before it finishes loses what it was still holding.
    ///
    /// Measured on this Mac, on an image, with nothing else in flight. A four
    /// megabyte file written with `dd conv=fsync` -- which returns only after
    /// the client's COMMIT has been answered -- and the machine then killed
    /// with `SIGKILL`:
    ///
    ///     XFS,  three runs:  lost exactly 32768 bytes at offset 0, every time
    ///     ext4, same test:   lost exactly 32768 bytes at offset 0
    ///     waiting 30s first: lost the same 32768 bytes
    ///     waiting 60s first: the whole file came back zero
    ///
    /// Same signature on both filesystems, so it is under them rather than in
    /// them, and waiting does not help because nothing is flushing in the
    /// meantime. `fsync` does not make data durable against a killed machine.
    ///
    /// `SIGTERM` does. The same test, 100 MB written and fsynced, then
    /// `SIGTERM`: the machine exited in **0.34 s** and all 100 MB came back
    /// byte for byte.
    ///
    /// So the half second was not wrong so much as unlucky -- it happened to
    /// be larger than the 0.34 s that one measurement needed, with nothing to
    /// spare and nothing behind it. A machine holding more, or emptying onto a
    /// drive that takes 7 MB/s rather than an SSD, needs longer, and what
    /// happens when it does not get it is silent: files that are the right
    /// length and quietly full of holes.
    ///
    /// Twenty seconds is the cap, not the cost. The wait ends the moment the
    /// process is gone, which in the measured case is a third of a second, so
    /// nothing a person waits on gets slower. Only a machine that is genuinely
    /// wedged pays the whole cap, and it is still killed at the end of it --
    /// a helper left running is the problem this exists to solve.
    static let flushGrace: TimeInterval = 20

    /// End the helpers in `pids`, having asked first.
    ///
    /// `SIGTERM` lets gvproxy remove its own sockets, and lets a machine put
    /// its writes on the disk. The second signal is for one that does not
    /// answer.
    public static func stop(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }

        // Waited out rather than slept through. Polling means the common case
        // costs what it actually takes -- a third of a second -- instead of a
        // fixed half second that is simultaneously too long for a helper with
        // nothing to write and too short for a machine with something to.
        let deadline = Date().addingTimeInterval(flushGrace)
        var stillThere = running().intersection(pids)
        while !stillThere.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            stillThere = running().intersection(pids)
        }
        for pid in stillThere { kill(pid, SIGKILL) }
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

        // A microVM that is still running has not lost anything. It may be
        // taking minutes to answer -- a drive gone slow, a Mac whose disk is
        // busy -- and that is not the same as a server that has gone, which is
        // the only thing this may act on.
        //
        // Silence alone was the test before, and silence is what a slow drive
        // produces. Reproduced on a 40 GB NTFS volume with the backing store
        // starved: writes stopped, probes went quiet, the mounts were called
        // dead, and the application unmounted the drive and quit the machine
        // that was still serving it -- mid-copy, twice, once with every earlier
        // fix already in place.
        //
        // Deliberately not gvproxy, which lingers after a mount that failed and
        // is exactly what the sweep is for.
        if !serving().isEmpty {
            Log.mount.notice("a microVM is still running; leaving its mounts alone")
            return []
        }

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

        // Asked again and again, over a minute, and only a mount that is silent
        // every single time has lost its server.
        //
        // It used to be one more probe a second later: about five seconds of
        // silence before `umount -f` and `rmdir`. That is not enough to justify
        // an action that cannot be undone. A microVM frozen by a busy Mac was
        // measured silent for forty seconds and came back serving its drive
        // perfectly; a drive that had gone slow was silent for fifteen minutes
        // and its copy would have continued. Five seconds of quiet cannot tell
        // any of those from a server that has actually gone.
        //
        // A minute is still fast enough for the thing this exists for -- macOS
        // refuses the next mount at a name still held by a dead one -- and that
        // is a wait, where the other way is somebody's copy destroyed.
        var dead = quiet
        for delay in [1.0, 4.0, 10.0, 20.0, 25.0] {
            guard !dead.isEmpty else { break }
            pause(delay)
            var stillQuiet: [String] = []
            for point in dead {
                switch answers(point) {
                case .silent: stillQuiet.append(point)
                case .alive: continue
                case .couldNotAsk: return []
                }
            }
            dead = stillQuiet
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
        unmountAsRoot: ((String) -> Bool)? = nil,
        opened: Set<String> = OpenedHere.all()
    ) -> Bool {
        let unmountAsRoot = unmountAsRoot ?? rootUnmount()
        // `opened` is passed in because the daemon cannot read it.
        //
        // OpenedHere is UserDefaults, and a daemon running as root reads root's
        // defaults -- always empty. So every candidate failed isOursToForce and
        // the helper's sweep did nothing at all, silently, which is the worst
        // way for a guard to fail: it looks like there was nothing to clear.
        // The helper reads the console user's own preferences and hands the set
        // over.
        let dead = deadEngineMounts(in: table, opened: opened)
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
