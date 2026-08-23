// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

// MARK: - Credential handling

public enum Credential {
    /// Normalise a credential using the shipped validator, which distinguishes a
    /// 48-digit numerical recovery password from an ordinary volume password.
    /// Returns the normalised value, or a human-readable reason for refusing it.
    public static func normalise(_ raw: String) -> Result<String, EngineError> {
        guard let validator = EnginePaths.validator,
            FileManager.default.fileExists(atPath: validator.path)
        else {
            // Without the validator, forward the credential untouched rather
            // than blocking the user.
            return .success(raw)
        }
        guard let result = run("/bin/bash", [validator.path, raw]) else {
            return .success(raw)
        }

        if result.ok {
            let value = result.out.trimmingCharacters(in: .newlines)
            return .success(value.isEmpty ? raw : value)
        }
        let reason = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(
            .credentialRejected(reason.isEmpty ? "That credential was not accepted." : reason))
    }

    /// Live feedback while typing, without validating hard enough to be annoying.
    public static func hint(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter { $0.isNumber }
        let onlyKeyChars = trimmed.allSatisfy { $0.isNumber || $0 == "-" || $0 == " " }
        guard onlyKeyChars, digits.count >= 20 else { return nil }
        if digits.count == 48 { return "Recovery key — 48 digits" }
        return "Recovery key — \(digits.count) of 48 digits"
    }
}
