// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import Foundation

/// Notices the machine going to sleep and coming back.
///
/// Sleeping with a drive open changes nothing about the drive: it stays
/// mounted, the microVM holding it stays where it is, and the person who closed
/// the lid is not asked to decide anything. What sleeping does change is that
/// the mount cannot answer for a while after the lid opens, so the app stops
/// asking it questions while the machine is away and checks quietly that it is
/// back before carrying on.
final class SleepWatch {
    private let willSleep: () -> Void
    private let didWake: () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
    }

    func start() {
        guard tokens.isEmpty else { return }
        let centre = NSWorkspace.shared.notificationCenter
        tokens = [
            centre.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.willSleep() },
            centre.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.didWake() },
        ]
    }

    deinit {
        let centre = NSWorkspace.shared.notificationCenter
        for token in tokens { centre.removeObserver(token) }
    }
}
