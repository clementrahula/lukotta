import Foundation

/// The stages a mount goes through, derived from what the engine reports.
public enum MountStage: Int, CaseIterable {
    case preparing, authorising, starting, unlocking, sharing

    public var title: String {
        switch self {
        case .preparing: return "Preparing"
        case .authorising: return "Waiting for your approval"
        case .starting: return "Starting the Linux environment"
        case .unlocking: return "Unlocking the drive"
        case .sharing: return "Handing the drive to Finder"
        }
    }

    /// Best guess at the current stage from the engine's own words. Matching on
    /// text is inherently loose, so it only ever moves the indicator forward.
    public static func inferred(from lines: [String]) -> MountStage {
        var stage = MountStage.preparing
        for line in lines {
            let l = line.lowercased()
            func advance(_ s: MountStage) { if s.rawValue > stage.rawValue { stage = s } }
            if l.contains("approval") || l.contains("administrator") { advance(.authorising) }
            if l.contains("krun") || l.contains("vm") || l.contains("kernel")
                || l.contains("boot") || l.contains("linux")
            {
                advance(.starting)
            }
            if l.contains("passphrase") || l.contains("luks") || l.contains("crypt")
                || l.contains("bitlocker") || l.contains("unlock")
            {
                advance(.unlocking)
            }
            if l.contains("nfs") || l.contains("export") || l.contains("mount")
                || l.contains("share")
            {
                advance(.sharing)
            }
        }
        return stage
    }
}
