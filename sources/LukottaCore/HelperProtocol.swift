// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Names shared by the application and the privileged helper.
public enum HelperInfo {
    /// The identifier every other name here is built from.
    ///
    /// Read from the bundle rather than written down, so an unbranded build
    /// gets its own service and daemon without a second set of constants to
    /// keep in step. The helper runs from `Contents/MacOS` of the same bundle,
    /// so it reads the identifier the app does.
    public static let appIdentifier = identifierOfTheApp(
        behind: Bundle.main.bundleIdentifier ?? "com.example.driveunlocker")

    /// The app's identifier, whether this is the app asking or the helper.
    ///
    /// The helper carries its own Info.plist inside the binary, because
    /// SMJobBless requires one -- and an embedded plist wins over the bundle
    /// the executable happens to sit in, so the helper reads its own identifier
    /// here rather than the app's. Everything below is composed from the app's:
    /// the mach service, the code requirement each side demands of the other,
    /// the paths the daemon removes itself from. With the suffix left on, the
    /// helper listened on <id>.helper.helper, refused the only app allowed to
    /// talk to it, and looked for itself in the wrong place -- which is a
    /// daemon that installs and then serves nobody.
    public static func identifierOfTheApp(behind identifier: String) -> String {
        let suffix = ".helper"
        guard identifier.hasSuffix(suffix) else { return identifier }
        return String(identifier.dropLast(suffix.count))
    }

    public static let machServiceName = "\(appIdentifier).helper"
    public static let plistName = "\(machServiceName).plist"

    /// Where launchd keeps the job when the daemon was installed with an
    /// administrator password. Only root can write here, so its presence is
    /// what says the daemon is installed that way.
    public static var installedJobPath: String {
        "/Library/LaunchDaemons/\(plistName)"
    }

    /// And where the binary it runs is put.
    public static var installedToolPath: String {
        "/Library/PrivilegedHelperTools/\(machServiceName)"
    }

    /// Whether a string is safe to paste into a code requirement.
    ///
    /// The identifier comes from a signed bundle, so changing it invalidates
    /// the signature. Checked anyway: a requirement is parsed, and a quote
    /// smuggled into one would change what it means rather than fail it.
    public static func isWellFormed(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 255
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
            }
    }

    /// Only a binary satisfying this may talk to the helper.
    ///
    /// Without it, any process on the machine could ask a root daemon to mount
    /// disks. The team is the one that signed the helper, read from its own
    /// signature rather than written down here, so a fork that signs with its
    /// own certificate pins to itself. Returns nil when either half fails to
    /// check out, and the helper then talks to nobody.
    public static func clientRequirement(team: String) -> String? {
        guard isWellFormed(appIdentifier), isWellFormed(team) else { return nil }
        return """
            anchor apple generic \
            and identifier "\(appIdentifier)" \
            and certificate leaf[subject.OU] = "\(team)"
            """
    }
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

    /// The same, with a choice of whether the drive may be written to.
    ///
    /// A second method rather than a parameter added to the one above, because
    /// the parameter list is the Objective-C selector: changing it would leave a
    /// freshly updated app calling a still-running older helper that has no such
    /// method and never answers. The old selector stays, so an old helper still
    /// serves a read-write mount, and the app falls back to it.
    func mount(
        devicePath: String,
        aliasPath: String?,
        isLinux: Bool,
        volumeIdentifier: String?,
        credential: String,
        readOnly: Bool,
        reply: @escaping (Int32, String) -> Void)

    /// The transcript of the mount running right now, as far as it has got.
    ///
    /// Polled rather than pushed back over the connection: the helper stays a
    /// thing that answers questions, and never needs the client to export an
    /// object for it to call into.
    func progress(reply: @escaping (String) -> Void)

    func unmount(mountPoint: String, reply: @escaping (Int32, String) -> Void)

    /// What a partition actually holds, read from its first sector.
    ///
    /// Here rather than in the app because /dev/diskNsM is mode 640 owned by
    /// root and the operator group, which an ordinary account is not in. Full
    /// Disk Access does not help: that is a POSIX permission, not a privacy
    /// one. Replies with a `VolumeFormat` raw value.
    func identify(devicePath: String, reply: @escaping (String) -> Void)

    func helperVersion(reply: @escaping (String) -> Void)

    /// Stop, so launchd starts the build that is on disk now.
    ///
    /// launchd keeps a registered daemon running across an app update: the
    /// binary inside the bundle is replaced and the process is not, and
    /// unregistering and registering again does not disturb one that is already
    /// running. So a fixed app went on being served by the broken daemon, with
    /// nothing to say so beyond a version the app noticed and could do nothing
    /// about.
    ///
    /// Only the daemon can end the daemon: it is root and the app is not. It
    /// replies first, then exits; launchd starts it again on the next call, and
    /// that one comes from the bundle as it is now.
    func stepAside(reply: @escaping (Bool) -> Void)

    /// Take yourself off this Mac: unload the job, remove it, remove the
    /// binary. Only the daemon can do this, because only root may write where
    /// those live -- and asking for the password a second time to undo
    /// something is the sort of thing that makes people leave it installed.
    func removeYourself(reply: @escaping (Bool) -> Void)

    /// Add loopback addresses, so more than three drives can be open at once.
    ///
    /// Every open drive is a virtual machine serving NFS, and NFS has one port,
    /// so each machine needs an address of its own. A Mac has three loopback
    /// addresses out of the box and adding more needs root, which is why it is
    /// asked of the helper. Each is a kernel entry: no process, no memory.
    ///
    /// Replies with how many the interface has afterwards. Idempotent, and safe
    /// to call whenever: addresses already there are left alone.
    func makeRoom(forDrives count: Int, reply: @escaping (Int) -> Void)
}
