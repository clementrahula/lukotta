import Foundation

/// How full a mounted volume is.
///
/// Read with statfs rather than through URL resource values: the drives here
/// are reached over NFS, and the capacity keys Foundation prefers are answered
/// by the local filesystem's notion of the volume rather than the one the
/// engine is serving.
public struct VolumeSpace: Equatable, Sendable {
    public let free: Int64
    public let total: Int64

    public var used: Int64 { max(0, total - free) }

    /// nil when the mount point cannot be read, which is the normal answer for
    /// a volume that has just gone away.
    public static func of(_ mountPoint: String) -> VolumeSpace? {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        let total = Int64(info.f_blocks) * block
        // f_bavail, not f_bfree: the second counts blocks reserved for root,
        // which nobody using the drive can have.
        let free = Int64(info.f_bavail) * block
        guard total > 0 else { return nil }
        return VolumeSpace(free: free, total: total)
    }

    /// "412,3 GB free of 500,1 GB", in the reader's own units and separators.
    public var summary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let f = formatter.string(fromByteCount: free)
        let t = formatter.string(fromByteCount: total)
        return appString("\(f) free of \(t)")
    }
}
