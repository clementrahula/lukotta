// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The stages a mount goes through, derived from what the engine reports.
public enum MountStage: Int, CaseIterable, Sendable {
    case preparing, authorising, working, finishing

    /// The steps a particular mount actually goes through.
    ///
    /// Only one route waits for anything: the one that asks macOS to authorise
    /// a single command. With the helper registered, or with a container file
    /// this user attached, nothing is asked for and nothing waits -- a step
    /// that appears, is marked done in the same instant, and can only be read
    /// as something the reader failed to do.
    public static func shown(askingApproval: Bool) -> [MountStage] {
        askingApproval ? allCases : allCases.filter { $0 != .authorising }
    }

    /// Shown as the step list, so it is looked up rather than returned as
    /// written: Text(String) prints what it is given.
    public var title: String {
        switch self {
        case .preparing: return appString("Preparing")
        case .authorising: return appString("Waiting for your approval")
        case .working: return appString("Unlocking and mounting")
        case .finishing: return appString("Handing the drive to Finder")
        }
    }

    /// Derived from markers the script writes, not from engine output.
    ///
    /// The engine prints almost nothing between starting and finishing, so an
    /// indicator driven by its words sits on one step and then jumps.
    public static func inferred(from lines: [String]) -> MountStage {
        var stage = MountStage.preparing
        for line in lines {
            if line.contains(MountScript.stageMarker + "authorised") {
                stage = max(stage, .authorising)
            }
            if line.contains(MountScript.stageMarker + "working") {
                stage = max(stage, .working)
            }
            // Only an actual mount means this stage was reached. Matching on
            // "nfs" would catch "NFS server not ready", which is a failure, and
            // make a mount that never started look nearly finished.
            if line.contains(" on /Volumes/") {
                stage = max(stage, .finishing)
            }
            if line.lowercased().contains("approval") {
                stage = max(stage, .authorising)
            }
        }
        return stage
    }
}

extension MountStage: Comparable {
    public static func < (a: MountStage, b: MountStage) -> Bool { a.rawValue < b.rawValue }
}
