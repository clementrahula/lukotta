// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

// MARK: - Engine state

public struct EngineMount: Equatable, Sendable {
    public let devicePath: String  // /dev/disk4s1
    public let mountPoint: String  // /Volumes/BACKUP
    /// The driver it was mounted with: ntfs3, btrfs, ext4. What is inside an
    /// encrypted drive is known only once it is open, and this is where the
    /// engine says it.
    public var driver: String = ""
}

/// What the engine itself reports, rather than what we can infer by parsing
/// `mount` output. Runs unprivileged, so the app can check state at any time.
public enum EngineStatus {

    /// What the engine says is mounted, or **nothing at all** when it could not
    /// be asked.
    ///
    /// The difference is the whole point. An engine that answers "no mounts"
    /// and an engine that cannot be reached produce the same empty list, and
    /// they mean opposite things: the first says a mount is finished with, the
    /// second says we do not know. `stale()` acts on that answer by unmounting,
    /// so treating the second as the first destroys a mount that is perfectly
    /// alive -- and with it whatever was being copied through it.
    ///
    /// Reproduced: under heavy disk load the engine's own `status` call fails
    /// to return, every live mount is read as abandoned, and the application
    /// force-unmounts the drive somebody is copying to and tells the microVM to
    /// quit. The engine log shows it plainly -- "Share was unmounted",
    /// "Received command: 'Quit'" -- and the copy ends there.
    ///
    /// So the two are kept apart here, and nothing destructive runs on a
    /// question that was never answered.
    public static func currentIfAnswered() -> [EngineMount]? {
        guard let engine = EnginePaths.anylinuxfs,
            FileManager.default.fileExists(atPath: engine.path)
        else { return nil }
        switch LukottaCore.ask(
            engine.path, ["status"],
            environment: EngineEnvironment.environmentForEngine())
        {
        // Ran, finished, and said it succeeded. Only this is an answer.
        case .finished(let output) where output.status == 0: return parse(output.out)
        // Ran and failed. Its output is not a list of no mounts, it is no list
        // at all -- and `status` exiting non-zero while printing nothing looks
        // exactly like an engine serving nothing.
        case .finished: return nil
        // Ran and was still going when the deadline passed. A wedged engine,
        // which is the state this whole question exists to survive.
        case .silent: return nil
        case .couldNotAsk: return nil
        }
    }

    /// The same, for callers that only read it. An unanswered question and an
    /// empty answer are both "nothing to show", which is harmless where nothing
    /// is torn down as a result.
    public static func current() -> [EngineMount] {
        currentIfAnswered() ?? []
    }

    /// "/dev/disk4s1 on /Volumes/BACKUP (ntfs3, ...) VM[cpus: 4, ram: 2048 MiB]"
    public static func parse(_ text: String) -> [EngineMount] {
        // Any absolute source, not only /dev/ — the engine also mounts disk
        // images — and the lvm:/raid: identifiers it uses for volumes inside a
        // container. A mount it reports is a mount worth resuming.
        MountTableEntry.all(in: text)
            .filter { entry in
                (entry.source.hasPrefix("/") || entry.source.hasPrefix("lvm:")
                    || entry.source.hasPrefix("raid:")) && entry.mountPoint.hasPrefix("/")
            }
            .map {
                EngineMount(
                    devicePath: $0.source, mountPoint: $0.mountPoint,
                    driver: $0.options.split(separator: ",").first.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? "")
            }
    }

    /// Mount points macOS still shows for a microVM that is no longer running.
    ///
    /// If the virtual machine goes away with an NFS mount still up — it
    /// crashed, or was killed — the mount outlives it, and macOS keeps
    /// reporting "server connections interrupted" until something clears it.
    /// That dialog belongs to the system and cannot be suppressed; the dead
    /// mount behind it can be removed, which is the part we can do.
    public static func stale() -> [String] {
        // Nothing is cleared on a question the engine never answered. Silence
        // is not "no mounts"; it is no information, and the action taken on the
        // answer is irreversible.
        guard let answered = currentIfAnswered() else { return [] }
        let live = answered.map(\.mountPoint)
        // A multi-volume mount nests per-volume mounts inside the primary, and
        // the engine reports only the primary: anything under a live mount is
        // alive too, not abandoned. What is genuinely stale is cleared deepest
        // first, or a parent would be detached with its children still mounted.
        return engineMountPoints(in: mountTable())
            .filter { point in
                !live.contains(point) && !live.contains { point.hasPrefix($0 + "/") }
            }
            .sorted {
                $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count
            }
    }

    /// Which entries of `mount` output this engine is responsible for.
    ///
    /// Recognised by the export path, so a network share the user mounted
    /// themselves is never touched: the engine exports under /mnt, and
    /// Lukotta's multi-volume action exports under /run.
    public static func engineMountPoints(in text: String) -> [String] {
        MountTableEntry.all(in: text)
            .filter { entry in
                entry.isNFS && entry.mountPoint.hasPrefix("/")
                    && (entry.source.contains(":/mnt/") || entry.source.contains(":/run/"))
            }
            .map(\.mountPoint)
    }

    /// NFS mounts nested under a drive's mount point — one per logical volume
    /// when a container held several. Read from the system mount table because
    /// the engine's status reports only the primary mount, and the nested ones
    /// are what the user actually opens.
    public static func nestedVolumes(under mountPoint: String) -> [String] {
        nestedVolumes(under: mountPoint, in: mountTable())
    }

    /// "server:/run/T7/HOME on /Volumes/T7/HOME (nfs, ...)"
    public static func nestedVolumes(under mountPoint: String, in mountText: String) -> [String] {
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        return MountTableEntry.all(in: mountText)
            .filter { $0.isNFS && $0.mountPoint.hasPrefix(prefix) }
            .map(\.mountPoint)
    }

    /// Detach a mount whose server is already gone. The ordinary unmount asks
    /// the server to co-operate, which a dead one cannot do.
    @discardableResult
    public static func forceUnmount(mountPoint: String) -> Bool {
        run("/sbin/umount", ["-f", mountPoint])?.ok ?? false
    }

    /// How long the engine is given to tear a mount down before it is treated
    /// as stuck.
    ///
    /// It is told to wait thirty seconds for the virtual machine, so anything
    /// past that is the engine itself not returning rather than the machine
    /// being slow. Ten seconds of margin, and then the interface gets an answer
    /// instead of a spinner that never stops.
    public static let unmountTimeout: TimeInterval = 40

    /// Unmount and wait for the microVM to exit. Unprivileged - the engine
    /// tears down the VM it started, so ejecting never needs a password.
    @discardableResult
    public static func unmount(mountPoint: String, timeout: TimeInterval = unmountTimeout) -> (
        ok: Bool, message: String
    ) {
        guard let engine = EnginePaths.anylinuxfs else { return (false, "Engine missing.") }
        // A deadline, because ejecting a drive that has gone away can otherwise
        // wait for ever, and nil comes back for both a failure to start and a
        // deadline passed.
        guard
            let result = run(
                engine.path, ["unmount", mountPoint, "--wait-for-vm", "30"], timeout: timeout,
                environment: EngineEnvironment.environmentForEngine())
        else {
            return (
                false,
                appString(
                    "The drive did not finish ejecting. It may still be in use, so try again or eject it in Finder."
                )
            )
        }

        let combined = result.combined
        if result.ok { return (true, combined) }
        // Busy volumes are the common case and deserve a usable sentence.
        if combined.lowercased().contains("busy") || combined.lowercased().contains("in use") {
            return (
                false, "The drive is in use. Close any open files or apps using it, then try again."
            )
        }
        return (false, combined.isEmpty ? "The drive could not be ejected." : combined)
    }
}
