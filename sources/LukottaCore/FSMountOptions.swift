// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What a mount asked the filesystem extension for.
///
/// The options arrive as `FSTaskOptions.taskOptions`, which is the argument
/// list `mount` was given, already split. They are the only channel into the
/// module: an appex is launched by `fskitd`, not by whoever ran the command, so
/// it inherits no environment and no working directory. An earlier version of
/// this read `LUKOTTA_FS_ROOT` out of the environment, which meant it was never
/// set in the one situation that matters.
///
/// Kept out of the extension so the parsing can be exercised without a mount,
/// and out of FSKit's types so LukottaCore does not need macOS 15.4.
public enum FSMountOptions {

    /// `-o` values, taken apart. `mount` passes them through as one
    /// comma-separated argument, which is the convention every filesystem uses:
    ///
    ///     mount -F -t lukottafs -o ro,root=/tmp/x device point
    public static func values(in options: [String]) -> [String: String] {
        var found: [String: String] = [:]
        var expectingValue = false
        for option in options {
            if option == "-o" {
                expectingValue = true
                continue
            }
            guard expectingValue else { continue }
            expectingValue = false
            for pair in option.split(separator: ",", omittingEmptySubsequences: true) {
                let halves = pair.split(
                    separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(halves[0]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                found[name] = halves.count > 1 ? String(halves[1]) : ""
            }
        }
        return found
    }

    /// Whether the mount asked for read-only.
    ///
    /// `ro` and `rdonly` are both spelled by things that mount volumes, and a
    /// read-only mount that is served writable is a drive somebody asked not to
    /// change and changed.
    public static func isReadOnly(_ options: [String]) -> Bool {
        let values = values(in: options)
        return values["ro"] != nil || values["rdonly"] != nil
    }

    /// The directory to serve, where one was named.
    ///
    /// Only ever an absolute path. A relative one would be resolved against
    /// whatever directory `fskitd` happened to start the extension in, which is
    /// nobody's idea of where their files are.
    public static func backingRoot(_ options: [String]) -> String? {
        guard let root = values(in: options)["root"], !root.isEmpty else { return nil }
        guard root.hasPrefix("/") else { return nil }
        return root
    }
}
