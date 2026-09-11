// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import LukottaCore

/// How long the last opens took, for the estimate on the opening screen.
enum OpenTimes {
    static let key = "RecentOpenSeconds"

    static func record(_ seconds: TimeInterval) {
        let all = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        UserDefaults.standard.set(Array((all + [seconds]).suffix(5)), forKey: key)
    }

    /// The median of the last five, so one slow open does not move it.
    static var expected: TimeInterval? {
        let all = (UserDefaults.standard.array(forKey: key) as? [Double] ?? []).sorted()
        return all.isEmpty ? nil : all[all.count / 2]
    }
}

/// The Linux environment brought up to date at launch, so an open after an update does not wait.
enum EnvironmentWarmup {
    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var line = ""
        private var busy = false
        func begin() { lock.withLock { busy = true } }
        func say(_ text: String) { lock.withLock { line = text } }
        func end() { lock.withLock { busy = false } }
        var state: (line: String, running: Bool) { lock.withLock { (line, busy) } }
    }

    static let progress = Progress()

    static func start() {
        progress.begin()
        Task.detached(priority: .utility) {
            defer { progress.end() }
            do {
                try EngineEnvironment.prepare { progress.say($0) }
            } catch {
                Log.app.error("the Linux environment could not be prepared at launch: \(error)")
            }
        }
    }
}
