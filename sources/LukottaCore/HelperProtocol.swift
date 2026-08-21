import Foundation

/// Names shared by the application and the privileged helper.
public enum HelperInfo {
    public static let machServiceName = "com.clementrahula.lukotta.helper"
    public static let plistName = "com.clementrahula.lukotta.helper.plist"

    /// Only a binary satisfying this may talk to the helper.
    ///
    /// Without it, any process on the machine could ask a root daemon to mount
    /// disks. The requirement pins both the identity and the signing team.
    public static let clientRequirement = """
        anchor apple generic \
        and identifier "com.clementrahula.lukotta" \
        and certificate leaf[subject.OU] = "A1B2C3D4E5"
        """
}

/// What the privileged helper will do on request.
///
/// Deliberately not "run this script". The helper composes the command itself
/// from these parameters, so a caller cannot use it to run arbitrary code as
/// root even if the client check were somehow defeated.
@objc public protocol LukottaHelperProtocol {
    func mount(
        devicePath: String,
        aliasPath: String?,
        isLinux: Bool,
        volumeIdentifier: String?,
        credential: String,
        reply: @escaping (Int32, String) -> Void)

    /// The transcript of the mount running right now, as far as it has got.
    ///
    /// Polled rather than pushed back over the connection: the helper stays a
    /// thing that answers questions, and never needs the client to export an
    /// object for it to call into.
    func progress(reply: @escaping (String) -> Void)

    func unmount(mountPoint: String, reply: @escaping (Int32, String) -> Void)

    func helperVersion(reply: @escaping (String) -> Void)
}
