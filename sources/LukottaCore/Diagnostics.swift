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
        appName: String = LukottaCore.appName,
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
                // The report is named after the process, which since the launch
                // shim is "<app>-app". Matching the app's name as a prefix let
                // "Lukotta Beta-app-….ips" into a release's bug report, where
                // it sends whoever reads it looking in the wrong application.
                let name = url.lastPathComponent
                let mine = name.hasPrefix("\(appName)-app-") || name.hasPrefix("\(appName)-2")
                guard mine, url.pathExtension == "ips" else { return false }
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(modified) <= within else { return false }
                guard let build = currentBuild else { return true }
                // The .ips header is a JSON object on the first line. A report
                // whose header cannot be read says nothing about which build it
                // came from, and was included on that basis -- which is the one
                // reading that cannot be checked. Left out instead.
                guard let reported = buildRecorded(in: url) else { return false }
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

    /// The one way text leaves this app.
    ///
    /// Everything shown on a failure screen, kept in the status lines, written
    /// to the log, handed back by the helper or put in a report goes through
    /// here and through nothing else. Written as one function because the
    /// alternative is what was here before: two functions, applied in different
    /// combinations at eight call sites, so the markers were stripped from a
    /// failure's detail and not from its summary, and the home directory was
    /// stripped from nowhere at all.
    ///
    /// It removes, in order: this app's own markers, the credential by value,
    /// anything shaped like a recovery key, anything a tool labelled a secret,
    /// and the account name out of any path under the home directory.
    ///
    /// Drive names and file names are deliberately kept. A report is diagnosed
    /// by somebody reading it, and "photos.img would not open" is the whole
    /// content of most reports; that is why the report goes to an address and
    /// not to a public issue.
    public static func scrubbed(_ text: String, secret: String? = nil) -> String {
        redact(withoutMarkers(text), secret: secret)
    }

    /// The account name, out of any path that carries it.
    ///
    /// A report is full of paths -- the engine prints its rootfs, the mount
    /// point, the image somebody opened -- and every one of them starts
    /// /Users/<account>. That is a person's name, on its way to an inbox, for
    /// no diagnostic gain: what matters is that the path was under the home
    /// directory, not whose.
    public static func withoutTheAccountName(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Any home, not only one under /Users. A network account, a mobile
        // account, or a Mac where somebody moved the home directories has a
        // home somewhere else entirely -- and the promise that a report carries
        // no name is a promise to them too. The name is the last component
        // whatever the path in front of it is.
        let account = (home as NSString).lastPathComponent
        guard !home.isEmpty, home != "/", !account.isEmpty else { return text }
        var result = text.replacingOccurrences(of: home, with: "~")
        // The account can also arrive on its own, from a tool that prints the
        // user rather than the path: SUDO_USER, "mounted by <account>", an
        // owner column. Only as a whole word, so a drive named after somebody
        // is left alone.
        if account.count >= 3 {
            result = result.replacingOccurrences(
                of: #"(?<![A-Za-z0-9._-])"# + NSRegularExpression.escapedPattern(for: account)
                    + #"(?![A-Za-z0-9._-])"#,
                with: "[account]", options: [.regularExpression])
        }
        return result
    }

    public static func redact(_ text: String) -> String {
        var result = withoutTheAccountName(text)

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
    /// Put a typed description into a report built without one.
    ///
    /// The rest of a report is fixed while the sheet is open — the engine's
    /// output, the log, the crash report — so it is redacted once. Only what
    /// somebody is still typing has to be redacted again as they type. The
    /// description goes where `report` puts it, above the engine's output.
    public static func withProblem(_ problem: String, in report: String) -> String {
        guard !problem.isEmpty else { return report }
        var lines = report.components(separatedBy: "\n")
        // After the four header lines, which every report begins with.
        let after = min(4, lines.count)
        lines.insert(contentsOf: ["", "What happened:", scrubbed(problem)], at: after)
        return lines.joined(separator: "\n")
    }

    public static func report(
        environment: Environment,
        problem: String? = nil,
        engineOutput: String? = nil,
        crashReport: URL? = nil,
        recentLog: String? = nil,
        parts: [Component]? = nil
    ) -> String {
        var lines = [
            // The build's own name: a report from the beta that says Lukotta is
            // a report about the wrong application, and the fault gets looked
            // for in the release.
            "\(appName) \(environment.appVersion) (build \(environment.build))",
            "\(environment.systemVersion) on \(environment.model)",
            "Engine embedded: \(environment.engineEmbedded ? "yes" : "no")",
            "Full Disk Access: \(environment.fullDiskAccess ? "granted" : "not granted")",
        ]
        if let problem, !problem.isEmpty {
            lines.append("")
            lines.append("What happened:")
            lines.append(scrubbed(problem))
        }
        // What the app is made of. The version at the top says which release
        // this is; it does not say which engine, which Linux image or which
        // helper is actually running, and those go out of step with it. A
        // report that leaves them out cannot distinguish a fault in this
        // release from one in an environment installed a year ago.
        let made = parts ?? Components.all()
        if !made.isEmpty {
            lines.append("")
            lines.append(Components.summary(made))
        }
        if let engineOutput, !engineOutput.isEmpty {
            lines.append("")
            lines.append("Engine output:")
            // Enough to diagnose, not so much that it cannot be pasted.
            lines.append(scrubbed(String(engineOutput.suffix(4000))))
        }
        if let recentLog, !recentLog.isEmpty {
            lines.append("")
            lines.append("What the app was doing:")
            lines.append(scrubbed(recentLog))
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
        let subject = "\(appName) \(environment.appVersion) — issue report"
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
