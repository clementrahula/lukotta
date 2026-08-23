// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import OSLog

/// Gathers what a useful bug report needs, and finds crash logs macOS has
/// already written.
///
/// The system crash dialog offers to report to Apple, which the developer of a
/// Developer ID application never sees. macOS writes the same report to
/// ~/Library/Logs/DiagnosticReports as an .ips file, so the app can offer it
/// directly on the next launch.
public enum Diagnostics {
    /// Where a report is best sent: a public issue, with the templates.
    ///
    /// One person reads the email, and reads it when they get to it. An issue
    /// is seen sooner, and the next person with the same drive finds the answer
    /// instead of writing the same message again.
    public static let newIssueURL =
        "https://github.com/clementrahula/lukotta/issues/new/choose"

    public struct Environment: Sendable {
        public var appVersion: String
        public var build: String
        public var systemVersion: String
        public var model: String
        public var engineEmbedded: Bool
        public var fullDiskAccess: Bool
    }

    public static func environment() -> Environment {
        let info = Bundle.main.infoDictionary
        return Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: hardwareModel(),
            engineEmbedded: EnginePaths.embeddedEngineRoot != nil,
            fullDiskAccess: Permissions.hasFullDiskAccess)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        let bytes = chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Crash reports macOS has written for this application, newest first.
    ///
    /// Only recent reports, and only for the build that is running.
    ///
    /// A report from an earlier build, offered beside an unrelated failure,
    /// reads as "this just crashed". A report from a build the user is not
    /// running is not evidence about the one they are.
    public static func crashReports(
        appName: String = "Lukotta",
        within: TimeInterval = 24 * 60 * 60,
        limit: Int = 5
    ) -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        return
            entries
            .filter { url in
                guard url.lastPathComponent.hasPrefix(appName), url.pathExtension == "ips"
                else { return false }
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(modified) <= within else { return false }
                guard let build = currentBuild else { return true }
                // The .ips header is a JSON object on the first line.
                guard let reported = buildRecorded(in: url) else { return true }
                return reported == build
            }
            .sorted { a, b in
                let x =
                    (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let y =
                    (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return x > y
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Strip Lukotta's own markers from engine output.
    ///
    /// They are written into the same log the engine writes to, because that is
    /// the only channel that survives the trip back from root. They are not
    /// output anyone should be shown or asked to report.
    public static func withoutMarkers(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.contains("LUKOTTA_") }
            .joined(separator: "\n")
    }

    /// Removes anything credential-shaped from text that may be shown, stored
    /// or sent, knowing the credential in play.
    ///
    /// The credential is never deliberately written anywhere: it travels
    /// through a FIFO and is referenced in the elevated script as a shell
    /// variable. But engine output is captured verbatim, and a tool that echoed
    /// a passphrase — or a future change to one — would put it in a log the
    /// user is invited to send. Redaction is applied to everything, so being
    /// wrong about that costs nothing.
    ///
    /// The pattern rules below recognise the shape of a recovery key, which is
    /// no help against an ordinary passphrase. One can still reach the log: the
    /// engine is driven through a pty, and a pty echoes what is typed into it,
    /// so a passphrase can come back in the engine's own output. When the exact
    /// secret is known, remove it by value rather than hoping it looks like
    /// something.
    public static func redact(_ text: String, secret: String?) -> String {
        var result = text
        if let secret {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            // Any length. Replacing the exact secret cannot match anything but
            // that secret, so there is nothing to be gained by declining to do
            // it for a short one — and a passphrase of one or two characters is
            // legal, so declining left the shortest secrets in the log.
            if !trimmed.isEmpty {
                result = result.replacingOccurrences(of: trimmed, with: "[redacted]")
            }
        }
        return redact(result)
    }

    public static func redact(_ text: String) -> String {
        var result = text

        // A BitLocker recovery password: eight six-digit groups, separated or
        // not, and the partial forms a log might contain.
        let patterns = [
            #"\b\d{6}(?:[- ]\d{6}){3,7}\b"#,  // grouped, four or more groups
            #"\b\d{40,60}\b"#,  // one long run of digits
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "[recovery key redacted]",
                options: [.regularExpression])
        }

        // Anything a tool labels as a secret, whatever follows the label.
        let labelled = #"(?i)\b(passphrase|password|key|secret|ALFS_PASSPHRASE)\b\s*[:=]\s*\S+"#
        result = result.replacingOccurrences(
            of: labelled, with: "$1: [redacted]",
            options: [.regularExpression])

        return result
    }

    // MARK: What the app said it was doing

    /// The last stretch of this process's own log.
    ///
    /// A report arrives long after the thing it is about, describing it from
    /// memory. This is what the app itself recorded at the time.
    ///
    /// `.currentProcessIdentifier` scope needs no entitlement: a process may
    /// always read back what it wrote. The system-wide scope does need one, and
    /// would return other applications' entries, which are neither wanted here
    /// nor ours to collect.
    ///
    /// Reads from disk, so never from the main thread. Anything logged as a
    /// private interpolation already reads as `<private>` by the time it gets
    /// here, which is the point of having marked it.
    public static func recentLog(within: TimeInterval = 900, limit: Int = 120) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "" }
        let subsystem = Log.subsystem
        let start = store.position(date: Date().addingTimeInterval(-within))
        guard
            let entries = try? store.getEntries(
                at: start, matching: NSPredicate(format: "subsystem == %@", subsystem))
        else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .map { entry in
                "\(formatter.string(from: entry.date)) \(entry.category) \(entry.composedMessage)"
            }
        return tail(of: lines, limit: limit)
    }

    /// The last `limit` lines, saying so when earlier ones were dropped.
    ///
    /// A report that silently begins in the middle reads as though nothing
    /// happened before it.
    public static func tail(of lines: [String], limit: Int) -> String {
        guard lines.count > limit else { return lines.joined(separator: "\n") }
        let dropped = lines.count - limit
        return (["… \(dropped) earlier lines not shown"] + lines.suffix(limit))
            .joined(separator: "\n")
    }

    /// The body of a report, ready to be copied or pasted into a message.
    public static func report(
        environment: Environment,
        problem: String? = nil,
        engineOutput: String? = nil,
        crashReport: URL? = nil,
        recentLog: String? = nil
    ) -> String {
        var lines = [
            "Lukotta \(environment.appVersion) (build \(environment.build))",
            "\(environment.systemVersion) on \(environment.model)",
            "Engine embedded: \(environment.engineEmbedded ? "yes" : "no")",
            "Full Disk Access: \(environment.fullDiskAccess ? "granted" : "not granted")",
        ]
        if let problem, !problem.isEmpty {
            lines.append("")
            lines.append("What happened:")
            lines.append(redact(problem))
        }
        if let engineOutput, !engineOutput.isEmpty {
            lines.append("")
            lines.append("Engine output:")
            // Enough to diagnose, not so much that it cannot be pasted.
            lines.append(redact(String(engineOutput.suffix(4000))))
        }
        if let recentLog, !recentLog.isEmpty {
            lines.append("")
            lines.append("What the app was doing:")
            lines.append(redact(recentLog))
        }
        if let crashReport {
            lines.append("")
            lines.append("Crash report: \(crashReport.lastPathComponent)")
        }
        return lines.joined(separator: "\n")
    }

    private static var currentBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// The build number recorded in a crash report's header.
    public static func buildRecorded(in report: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: report) else { return nil }
        defer { try? handle.close() }
        // The header line is short; reading the whole file would be wasteful.
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard
            let text = String(data: head, encoding: .utf8),
            let line = text.components(separatedBy: "\n").first,
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["build_version"] as? String
    }

    /// When a crash report was written, for showing alongside it.
    public static func date(of report: URL) -> Date? {
        (try? report.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// A mailto: URL. The body is kept short on purpose: mail clients and the
    /// shell both truncate a long URL, so the detail goes to the clipboard and
    /// the message asks for it to be pasted.
    public static func mailtoURL(address: String, environment: Environment) -> URL? {
        let subject = "Lukotta \(environment.appVersion) — issue report"
        let body = """
            (Please paste the copied details below, and describe what happened.)


            ---
            Lukotta \(environment.appVersion) (build \(environment.build))
            \(environment.systemVersion)
            """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
