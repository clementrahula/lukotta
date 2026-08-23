// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Asking whether a network mount is still answering, without being taken down
/// by the answer.
///
/// There is no safe way to ask in-process. `statfs` on a wedged NFS mount
/// blocks inside the kernel, takes no timeout, and cannot be cancelled: a
/// thread that enters the call stays there until the server replies, which for
/// a server that is never coming back is forever. So the question is asked from
/// a process that can be abandoned instead of a thread that cannot.
public enum MountProbe {

    /// Whether `mountPoint` replied within `timeout`.
    ///
    /// Blocks the calling thread for up to `timeout`, so never call it from the
    /// main actor. A false answer means "did not reply in time", which is not
    /// quite the same as gone — a machine that has just woken can be slow once
    /// and fine a second later, which is why the caller asks more than once.
    public static func isAnswering(_ mountPoint: String, timeout: TimeInterval = 5) -> Bool {
        // df, because it issues a request the server has to serve. Reading the
        // mount point itself proves nothing: the client answers that from its
        // own cache, and a dead mount looks healthy.
        // Not the shared runner: this deliberately collects no output, so that
        // a df already inside a wedged syscall can be abandoned without a pipe
        // still open on it.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/df")
        p.arguments = ["-k", mountPoint]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return false }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // A process already inside the syscall does not die on being asked;
            // it goes when the mount does. Abandoning it is the point — this
            // call returns either way, which the syscall would not have.
            p.terminate()
            return false
        }
        return p.terminationStatus == 0
    }
}

/// When to stop waiting for a mount to come back after the machine wakes.
///
/// Waking is not instant and is not one event: the host resumes, the microVM's
/// virtual CPUs resume some time after that, its clock is wrong until something
/// corrects it, and the network proxy between them has to carry traffic again
/// before the NFS server can answer anything. A mount that is silent one second
/// after the lid opens is normal. One that is still silent a minute later is
/// not.
public enum WakeRecovery {

    /// How long a mount is given to answer before it is treated as gone.
    ///
    /// Long enough to cover a slow resume, short enough that a drive which
    /// really did die is not left in the list pretending to be open.
    public static let grace: TimeInterval = 60

    /// How long to wait before asking again, having already been waiting
    /// `elapsed` seconds. Nil when the grace period is used up.
    ///
    /// Doubling, because the first few seconds are where the answer usually
    /// changes and there is no point asking a wedged mount every second for a
    /// minute — each question costs a process that may never come back.
    public static func nextDelay(after elapsed: TimeInterval, grace: TimeInterval = grace)
        -> TimeInterval?
    {
        guard elapsed < grace else { return nil }
        let delay = max(1, min(16, pow(2, (elapsed / 4).rounded(.down))))
        // Never propose a wait that runs past the grace period.
        return min(delay, grace - elapsed)
    }
}
