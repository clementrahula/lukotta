// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What of a failed open's transcript is shown under Details: what happened, never the script that ran.
public enum FailureDetail {
    public static func visibleLines(_ detail: String) -> [String] {
        detail.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty
                && !trimmed.contains(" action: `")
                && !trimmed.contains("ALFS_PASSPHRASE")
                && !trimmed.hasPrefix("+ ")
        }
    }
}
