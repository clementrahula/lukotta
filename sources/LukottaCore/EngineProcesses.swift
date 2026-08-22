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

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var found: Set<Int32> = []
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
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
