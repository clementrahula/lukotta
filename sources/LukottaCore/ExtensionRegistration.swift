// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Putting the filesystem extension back after an update has taken it away.
///
/// Measured on this Mac, 2026-08-28: replacing the installed application --
/// which is the whole of what an updater does -- leaves the appex on disk with
/// a valid signature and **de-registers it completely**. `pluginkit` reports the
/// module before the replacement and reports nothing at all afterwards. Not
/// re-registered under a new identifier: gone.
///
/// That matters more here than it would anywhere else, because the module has to
/// be switched on by hand once in System Settings and the application cannot
/// switch it on. An update that removes the module leaves somebody with a drive
/// that will not open until they find a switch nobody told them about.
///
/// What restores it, tried in order and measured:
///
///     lsregister -f  on the application    does not
///     lsregister -f  on the appex          does not
///     pluginkit -a   on the appex          restores it
///
/// So the repair is one call, and it is safe to make at launch.
///
/// **It is only ever made when the module is missing.** Registering one that is
/// already registered issues a new extension UUID, and on 2026-08-28 doing that
/// four times in an evening reset the owner's System Settings switch under them
/// every time -- they were clicking it on while this was turning it off. A
/// repair that runs unconditionally at every launch would do that to everybody,
/// for ever. Checking first is not an optimisation; it is the whole difference
/// between a repair and the fault.
public enum ExtensionRegistration {

    /// Where the extension lives inside a bundle, if it carries one.
    public static func appex(in bundle: Bundle = .main) -> URL? {
        guard let contents = bundle.builtInPlugInsURL?.deletingLastPathComponent() else {
            return nil
        }
        let extensions = contents.appendingPathComponent("Extensions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        guard let name = names.first(where: { $0.hasSuffix(".appex") }) else { return nil }
        return extensions.appendingPathComponent(name, isDirectory: true)
    }

    /// Whether macOS currently knows about a module with this identifier.
    ///
    /// Read from `pluginkit`, which is the only thing that answers it. This says
    /// nothing about whether the module is *enabled*: that is
    /// `FSModuleIdentity.enabled`, which is readonly, and the answer to it is a
    /// mount attempt.
    public static func isRegistered(_ identifier: String) -> Bool {
        guard let output = run("/usr/bin/pluginkit", ["-m", "-i", identifier]) else {
            // pluginkit could not be asked. Not knowing is not the same as
            // knowing it is absent, and the expensive mistake here is
            // registering something that is already there.
            return true
        }
        return output.combined.contains(identifier)
    }

    /// What a repair came to, so a caller can log the interesting case only.
    public enum Outcome: Equatable, Sendable {
        /// Already known to macOS. Nothing was done, which is the point.
        case alreadyRegistered
        /// This build carries no extension. Every channel but v2.
        case noExtension
        /// It was missing and has been put back.
        case repaired
        /// It was missing and could not be put back.
        case failed
    }

    /// Put it back if, and only if, it has gone.
    @discardableResult
    public static func repairIfMissing(
        identifier: String, in bundle: Bundle = .main
    ) -> Outcome {
        guard let appex = appex(in: bundle) else { return .noExtension }
        if isRegistered(identifier) { return .alreadyRegistered }
        Log.app.info("the filesystem extension is not registered; putting it back")
        guard run("/usr/bin/pluginkit", ["-a", appex.path]) != nil else { return .failed }
        return isRegistered(identifier) ? .repaired : .failed
    }

    /// Whether an outcome is worth a line in the log.
    ///
    /// Doing nothing is not. On every Mac where nothing has gone wrong, that is
    /// what happens at every launch, and a line each time would bury the one
    /// launch where something did.
    public static func isWorthLogging(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .alreadyRegistered, .noExtension: return false
        case .repaired, .failed: return true
        }
    }
}
