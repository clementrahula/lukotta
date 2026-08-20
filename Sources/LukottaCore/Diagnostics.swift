import Foundation

/// Gathers what a useful bug report needs, and finds crash logs macOS has
/// already written.
///
/// The system crash dialog offers to report to Apple, which the developer of a
/// Developer ID application never sees. macOS writes the same report to
/// ~/Library/Logs/DiagnosticReports as an .ips file, so the app can offer it
/// directly on the next launch.
public enum Diagnostics {

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
        return String(cString: chars)
    }

    /// Crash reports macOS has written for this application, newest first.
    public static func crashReports(appName: String = "Lukotta", limit: Int = 5) -> [URL] {
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
            .filter { $0.lastPathComponent.hasPrefix(appName) && $0.pathExtension == "ips" }
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

    /// Removes anything credential-shaped from text that may be shown, stored
    /// or sent.
    ///
    /// The credential is never deliberately written anywhere: it travels
    /// through a FIFO and is referenced in the elevated script as a shell
    /// variable. But engine output is captured verbatim, and a tool that echoed
    /// a passphrase — or a future change to one — would put it in a log the
    /// user is invited to send. Redaction is applied to everything, so being
    /// wrong about that costs nothing.
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

    /// The body of a report, ready to be copied or pasted into a message.
    public static func report(
        environment: Environment,
        problem: String? = nil,
        engineOutput: String? = nil,
        crashReport: URL? = nil
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
        if let crashReport {
            lines.append("")
            lines.append("Crash report: \(crashReport.lastPathComponent)")
        }
        return lines.joined(separator: "\n")
    }

    /// A mailto: URL. The body is kept short deliberately — mail clients and
    /// the shell both truncate long URLs, so the full detail goes to the
    /// clipboard and the message asks for it to be pasted.
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
