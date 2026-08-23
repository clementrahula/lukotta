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

/// The mount table as `mount` prints it.
///
/// Three files kept their own copy of this call. What each does with the table
/// differs; getting hold of it does not.
public func mountTable() -> String {
    run("/sbin/mount")?.out ?? ""
}
