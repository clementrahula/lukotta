// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The stages a mount goes through, derived from what the engine reports.
public enum MountStage: Int, CaseIterable, Sendable {
    case preparing, authorising, working, checking, finishing

    /// The steps a particular mount actually goes through.
    ///
    /// Only one route waits for anything: the one that asks macOS to authorise
    /// a single command. With the helper registered, or with a container file
    /// this user attached, nothing is asked for and nothing waits -- a step
    /// that appears, is marked done in the same instant, and can only be read
    /// as something the reader failed to do.
    /// Only the steps this mount actually goes through.
    ///
    /// Two of them are conditional, for the same reason: a step that appears,
    /// is marked done in the same instant and is never waited on can only be
    /// read as something the reader failed to do. Approval is asked for on one
    /// route only. A check runs on a damaged drive only -- it reads the whole
    /// MFT, 59 seconds on a 247 GB drive, measured -- and the great majority of
    /// drives never see one, so it appears when it starts rather than sitting
    /// in every list waiting to be skipped.
    public static func shown(askingApproval: Bool, checking: Bool = false) -> [MountStage] {
        allCases.filter {
            ($0 != .authorising || askingApproval) && ($0 != .checking || checking)
        }
    }

    /// Shown as the step list, so it is looked up rather than returned as
    /// written: Text(String) prints what it is given.
    public var title: String {
        switch self {
        case .preparing: return appString("Preparing")
        case .authorising: return appString("Waiting for your approval")
        case .working: return appString("Unlocking and mounting")
        case .checking: return appString("Checking this drive for damage")
        case .finishing: return appString("Handing the drive to Finder")
        }
    }

    /// Derived from markers the script writes, not from engine output.
    ///
    /// The engine prints almost nothing between starting and finishing, so an
    /// indicator driven by its words sits on one step and then jumps.
    /// Whether a check has started, which is what puts that step in the list.
    public static func isChecking(_ lines: [String]) -> Bool {
        lines.contains { $0.contains(MountScript.stageMarker + "checking") }
    }

    public static func inferred(from lines: [String]) -> MountStage {
        var stage = MountStage.preparing
        for line in lines {
            if line.contains(MountScript.stageMarker + "authorised") {
                stage = max(stage, .authorising)
            }
            if line.contains(MountScript.stageMarker + "working") {
                stage = max(stage, .working)
            }
            if line.contains(MountScript.stageMarker + "checking") {
                stage = max(stage, .checking)
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
