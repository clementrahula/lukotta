// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The engine's config.toml, which survives across mounts.
///
/// It sits inside this app's own engine directory, so it belongs to this app
/// alone: nothing else on the Mac reads or writes it, and this app writes to no
/// other copy of it. What goes in is one section under a name of its own,
/// `[custom_actions.lukotta]`, added before a multi-volume mount and taken away
/// after the eject.
///
/// Lukotta writes exactly one thing into it: the generated custom action that
/// serves every logical volume of a container. The mount script regenerates
/// that section on each multi-volume mount, and this type removes it once the
/// drive is ejected — the app aims to leave nothing behind that it still needs.
public enum EngineConfig {
    /// Inside this app's engine directory, which is what the engine is given
    /// as its home. See `EngineEnvironment.engineHome`.
    public static var path: String {
        EngineEnvironment.engineHome
            .appendingPathComponent(".anylinuxfs/config.toml").path
    }

    static var generatedHeader: String { "[custom_actions.\(MountScript.generatedAction)]" }

    /// The text with the generated section removed: its header line up to, but
    /// not including, the next section header. Pure, so the exact behaviour can
    /// be asserted; the engine canonicalises the file on every run, so headers
    /// are reliably alone on their line.
    public static func withoutGeneratedAction(_ text: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") { skipping = line == generatedHeader }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// Best-effort removal of the generated section.
    ///
    /// Written by truncating in place rather than atomically: the file may have
    /// been created by the elevated mount script, and replacing the inode would
    /// fail where rewriting the contents succeeds. Failing entirely is also
    /// fine — the section is inert once the mount is gone, and the next
    /// multi-volume mount overwrites it before use.
    public static func removeGeneratedAction() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let cleaned = withoutGeneratedAction(text)
        guard cleaned != text else { return }
        try? cleaned.write(toFile: path, atomically: false, encoding: .utf8)
    }

}
