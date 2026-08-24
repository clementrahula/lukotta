// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

// MARK: - Credential handling

public enum Credential {

    /// How many digits make something an attempt at a recovery key rather than
    /// a password. Below this a run of digits is somebody's password and is
    /// left alone; at or above it, a mistyped key is worth naming precisely.
    static let recoveryMinimumDigits = 20

    /// A numerical recovery password is eight groups of six digits.
    static let recoveryGroups = 8
    static let recoveryGroupLength = 6

    /// The largest a genuine group can be: a 16-bit value multiplied by 11.
    static let recoveryGroupCeiling = 65535 * 11

    /// Normalise a credential, telling a 48-digit numerical recovery password
    /// from an ordinary volume password.
    ///
    /// BitLocker takes either. They are told apart by shape: input made only of
    /// digits, spaces and hyphens carrying at least `recoveryMinimumDigits`
    /// digits is an attempt at a recovery key, and is then checked strictly --
    /// so a mistyped key says which group is wrong instead of coming back from
    /// cryptsetup half a minute later as "wrong key". Anything else is a
    /// password and is passed through exactly as typed, since spaces and
    /// punctuation are all significant in one.
    ///
    /// Returns the normalised value, or a reason to show for refusing it.
    public static func normalise(_ raw: String) -> Result<String, EngineError> {
        guard !raw.isEmpty else {
            return .failure(
                .credentialRejected(
                    appString("Enter the drive's password, or its 48-digit recovery key.")))
        }

        let digits = raw.filter(\.isNumber)
        let looksLikeRecovery =
            raw.allSatisfy { $0.isNumber || $0 == "-" || $0.isWhitespace }
            && digits.count >= recoveryMinimumDigits
        guard looksLikeRecovery else { return .success(raw) }

        let wanted = recoveryGroups * recoveryGroupLength
        guard digits.count == wanted else {
            return .failure(
                .credentialRejected(
                    appString(
                        "That looks like a recovery key, but it has \(digits.count) of the 48 digits. Check for a missing or repeated group."
                    )))
        }

        var groups: [String] = []
        for groupNumber in 1...recoveryGroups {
            let start = digits.index(
                digits.startIndex, offsetBy: (groupNumber - 1) * recoveryGroupLength)
            let end = digits.index(start, offsetBy: recoveryGroupLength)
            let group = String(digits[start..<end])
            // Divisibility by eleven is the per-group checksum Windows uses to
            // catch a mistyped recovery password, and the ceiling is what a
            // 16-bit value multiplied by eleven can reach.
            guard let value = Int(group), value <= recoveryGroupCeiling, value % 11 == 0 else {
                return .failure(
                    .credentialRejected(
                        appString(
                            "Group \(groupNumber) of the recovery key is not valid. Recheck those six digits."
                        )))
            }
            groups.append(group)
        }
        return .success(groups.joined(separator: "-"))
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
