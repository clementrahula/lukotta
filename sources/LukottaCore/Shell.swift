// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

// MARK: - Shell / AppleScript quoting

public func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func appleScriptQuoted(_ s: String) -> String {
    "\""
        + s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: - Running a program

/// What a program printed, and how it ended.
public struct CommandOutput: Sendable {
    public let status: Int32
    public let out: String
    public let err: String

    /// Both streams together, trimmed, for the cases where a program's
    /// complaint may arrive on either.
    public var combined: String {
        (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var ok: Bool { status == 0 }
}

/// Run a program and collect what it said.
///
/// Nil means it could not be started or did not finish inside the deadline;
/// the caller decides what that means, since a missing tool and a wedged one
/// need different sentences.
///
/// The deadline is watched before the pipes are read. Reading to the end of a
/// pipe waits for the writing end to close, which a process that will never
/// finish never does, so a read-then-wait ordering hangs on exactly the case
/// the deadline exists for.
///
/// Output is read after the process ends, which bounds what is collected by
/// what these programs print: a mount table, a plist, a few lines of status.
/// A program that fills the pipe buffer without exiting would deadlock, and
/// none of the callers here run one.
@discardableResult
public func run(
    _ executable: String,
    _ arguments: [String] = [],
    timeout: TimeInterval? = nil,
    environment: [String: String]? = nil
) -> CommandOutput? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }

    if let timeout {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
    }

    let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return CommandOutput(status: process.terminationStatus, out: output, err: errors)
}

/// One line of `mount` output, taken apart once.
///
/// Every line has the same shape — `source on point (options)` — and five
/// places used to find `" on "` and `" ("` for themselves. They differ in which
/// lines they keep, not in how a line is read.
public struct MountTableEntry: Sendable {
    /// What is mounted: a device, an image's path, or one of the engine's own
    /// `lvm:`/`raid:` identifiers.
    public let source: String
    public let mountPoint: String
    /// What stands between the brackets, `nfs, nodev, nosuid` and the rest.
    public let options: String

    /// Nil for a line that is not a mount: the header, a blank, anything else
    /// the table may grow.
    public init?(line: String) {
        guard let on = line.range(of: " on "),
            let open = line.range(of: " (", range: on.upperBound..<line.endIndex)
        else { return nil }
        source = String(line[line.startIndex..<on.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        mountPoint = String(line[on.upperBound..<open.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rest = line[open.upperBound...]
        options = String(rest.prefix(while: { $0 != ")" }))
    }

    /// Whether this is an NFS mount, which is how every mount the engine makes
    /// arrives on this Mac.
    public var isNFS: Bool { options.hasPrefix("nfs") }

    /// Whether this is one of the engine's own.
    ///
    /// Not every NFS mount is: an office Mac can have a file server mounted all
    /// day. Guarding on "any NFS anywhere" meant such a Mac could never remove
    /// its helper, never release the addresses it had added, and never move its
    /// Linux environment -- conservative, and permanent.
    ///
    /// The engine exports over loopback and names the share after the device it
    /// unlocked, which is what tells its mounts apart from a file server's.
    public var isEngineMount: Bool {
        guard isNFS else { return false }
        return source.contains(".local:/mnt/") || source.hasPrefix("127.0.0.")
    }
}

extension MountTableEntry {
    /// Every line of a table that is a mount.
    public static func all(in table: String) -> [MountTableEntry] {
        table.components(separatedBy: .newlines).compactMap(MountTableEntry.init(line:))
    }
}

/// The mount table as `mount` prints it.
///
/// Three files kept their own copy of this call. What each does with the table
/// differs; getting hold of it does not.
public func mountTable() -> String {
    run("/sbin/mount")?.out ?? ""
}
