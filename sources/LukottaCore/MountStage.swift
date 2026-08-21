import Foundation

/// The stages a mount goes through, derived from what the engine reports.
public enum MountStage: Int, CaseIterable, Sendable {
    case preparing, authorising, working, finishing

    public var title: String {
        switch self {
        case .preparing: return "Preparing"
        case .authorising: return "Waiting for your approval"
        case .working: return "Unlocking and mounting"
        case .finishing: return "Handing the drive to Finder"
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
