// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// How a drive is served: by the filesystem extension, or over NFS as before.
///
/// The extension makes a drive a local volume, which is what removes the
/// network semantics, the AppleDouble sidecar beside every file, and the macOS
/// NFS client's timers. It also cannot be turned on by this application:
/// `FSModuleIdentity.enabled` is readonly, `FSClient` only reads, and there is
/// no FSKit equivalent of the request that gets a system extension its prompt.
/// Somebody has to find a switch in System Settings, once, and on current macOS
/// that switch is reported not to stick.
///
/// So the extension is never the way a drive opens. It is the fast way, and NFS
/// is what happens otherwise:
///
///     try the extension; if it is not there, serve the drive over NFS,
///     and say nothing to anybody either way.
///
/// Nobody is asked, nobody is told, nobody is blocked. A person who never opens
/// System Settings gets what they got before. A person who turns it on gets a
/// local volume. An update that de-registers the extension costs speed rather
/// than costing them their drive -- which is the difference between a route
/// that can ship and one that cannot.
public enum FilesystemRoute: String, Sendable, Equatable {
    /// Served by LukottaFS. A local volume.
    case fileSystemExtension
    /// Served by the engine over NFS, as every drive is today.
    case network

    /// Which to try first.
    ///
    /// - Parameters:
    ///   - extensionAvailable: whether this build carries the extension at all.
    ///     Only the v2 channel does, and only on macOS 15.4 and later.
    ///   - readOnly: a read-only mount. The extension is not used for these
    ///     yet: the reason to reach for it is write behaviour, and a read-only
    ///     drive gets none of it while doubling what has to be proved.
    ///   - preferred: what the owner of the build asked for, where anything
    ///     asked at all. `nil` means take the fast one where it exists.
    public static func first(
        extensionAvailable: Bool,
        readOnly: Bool = false,
        preferred: FilesystemRoute? = nil
    ) -> FilesystemRoute {
        if let preferred { return preferred }
        guard extensionAvailable, !readOnly else { return .network }
        return .fileSystemExtension
    }

    /// What to do when a route did not work.
    ///
    /// The extension falls back to NFS, once. NFS falls back to nothing: it is
    /// the floor, and a failure there is a failure to report rather than
    /// something to retry differently.
    ///
    /// Deliberately not a loop. A fallback that can be taken twice is one that
    /// can be taken for ever, and a mount that keeps retrying is the wedge this
    /// application spent a version getting rid of.
    public static func after(_ failed: FilesystemRoute) -> FilesystemRoute? {
        switch failed {
        case .fileSystemExtension: return .network
        case .network: return nil
        }
    }

    /// Whether taking this route instead of the one asked for is worth telling
    /// anybody about.
    ///
    /// It is not, ever. That is the whole design: the drive opened, it is
    /// slower than it could have been, and the person did not ask for a
    /// filesystem extension and should not be told one is missing. Written as a
    /// function rather than left implicit so that the next person to consider
    /// adding a message finds the reason here first.
    public static var fallbackIsWorthSaying: Bool { false }
}
