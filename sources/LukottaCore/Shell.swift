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
