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

    /// Whether a header line is one of this app's own generated sections.
    ///
    /// Every drive gets its own name now -- `lukotta_<drive>` -- because one
    /// shared section meant two containers opening at once each replaced the
    /// other's, and a container's action carries its own scratch path, bind
    /// mounts and list of logical volumes. So removal matches the prefix rather
    /// than one exact string, and it still takes the old flat `lukotta` section
    /// left by a build before this change.
    ///
    /// Every generated section goes, not just the ejected drive's. The action is
    /// read once, when a mount is made, and regenerated on every mount -- so
    /// removing one another drive still has open costs that drive nothing, and
    /// leaving them costs a section per drive for ever. This Mac's config held a
    /// generated section still naming a device detached hours earlier.
    public static func isGeneratedHeader(_ line: String) -> Bool {
        let flat = "[custom_actions.\(MountScript.generatedActionPrefix.dropLast())]"
        let prefixed = "[custom_actions.\(MountScript.generatedActionPrefix)"
        return line == flat || (line.hasPrefix(prefixed) && line.hasSuffix("]"))
    }

    /// The text with the generated section removed: its header line up to, but
    /// not including, the next section header. Pure, so the exact behaviour can
    /// be asserted; the engine canonicalises the file on every run, so headers
    /// are reliably alone on their line.
    public static func withoutGeneratedAction(_ text: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") { skipping = isGeneratedHeader(line) }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// The same section named twice, which stops the engine reading the file at
    /// all.
    ///
    /// TOML has no opinion about which of two identical tables wins: it refuses
    /// the document. The engine then answers every mount, of every drive, with
    ///
    ///     Failed to parse config file .../config.toml:
    ///     duplicate key `lukottantfs3g` in table `custom_actions`
    ///
    /// and nothing opens until somebody edits the file by hand. Measured on
    /// 2026-09-05 after a harness appended the app's action block without
    /// removing every section that block defines: twenty volumes that had
    /// opened that morning all refused, and the app looked broken.
    ///
    /// This file belongs to this app, so this app repairs it rather than
    /// leaving a person with a drive that will not open and no way to know why.
    /// The first of each name is kept: the sections are regenerated on the next
    /// mount that needs them, so keeping the older copy costs nothing and
    /// choosing between them on content would be a guess.
    public static func withoutDuplicateActions(_ text: String) -> String {
        var kept: [String] = []
        var seen: Set<String> = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if let name = actionName(of: line) {
                skipping = seen.contains(name)
                seen.insert(name)
                if skipping { continue }
            } else if skipping, line.hasPrefix("[") {
                skipping = false
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// The action a header line names, or nil when it is not one.
    static func actionName(of line: String) -> String? {
        let prefix = "[custom_actions."
        guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    /// Take away any section named twice, if the file has one.
    ///
    /// Written back only when it changed, so an untouched config keeps its
    /// modification time and nothing is rewritten on every launch.
    public static func repairDuplicateActions() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let cleaned = withoutDuplicateActions(text)
        guard cleaned != text else { return }
        Log.app.notice("the engine config named a custom action twice; taking the repeat away")
        try? cleaned.write(toFile: path, atomically: false, encoding: .utf8)
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
