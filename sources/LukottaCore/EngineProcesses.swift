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

    /// The engine mounts in this table that no longer answer.
    ///
    /// Asked of each mount rather than inferred from the engines that happen to
    /// be running. "Nothing is running, so nothing is being served" was the
    /// first version of this and it is wrong exactly when it matters: the
    /// engine that left the mount behind is often still on its way out, and
    /// counted as though it were serving the mount it has already abandoned.
    ///
    /// The probe is a stat, in a process of its own with two seconds to answer.
    /// A live mount answers at once; one whose server has gone fails or does
    /// not answer at all, and the deadline is what keeps this from waiting on
    /// it the way everything else does.
    public static func deadEngineMounts(
        in table: String,
        answers: (String) -> Bool = { point in
            LukottaCore.run("/usr/bin/stat", ["-f", "%d", point], timeout: 2)?.status == 0
        }
    ) -> [String] {
        MountTableEntry.all(in: table).filter(\.isEngineMount).map(\.mountPoint)
            .filter { !answers($0) }
    }

    /// Take away mounts whose server has gone, and say whether any went.
    ///
    /// What one does when it is left: macOS refuses the next mount at that name
    /// -- "invalid file system" -- so the engine's request fails, and a drive
    /// asked for read-write falls through to the read-only attempt and opens
    /// read-only with nothing said. That is the shape it was found in.
    ///
    /// Forced, because a mount with no server does not come down politely.
    /// Mounted by this user, so this needs no privilege.
    @discardableResult
    public static func deadMountsCleared(in table: String) -> Bool {
        let dead = deadEngineMounts(in: table)
        guard !dead.isEmpty else { return false }
        Log.mount.notice("taking away \(dead.count, privacy: .public) mounts whose server has gone")
        for point in dead {
            _ = LukottaCore.run("/sbin/umount", ["-f", point])
            // The directory it was mounted on, which is this app's to remove
            // when nothing is on it. rmdir refuses anything else.
            _ = rmdir(point)
        }
        return true
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
