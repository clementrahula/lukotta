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

    /// What the daemon promises the app, as a number the app can compare.
    ///
    /// Not the app's build: that moves on every release, and comparing against
    /// it would ask for an administrator password after almost every update.
    /// This moves only when the daemon itself changes in a way that matters --
    /// a new method, a fixed one, a different answer to an old question -- and
    /// whoever changes the daemon is who raises it.
    ///
    /// 2: the daemon finds the engine in the application that called it, so a
    ///    drive opened through it works when the daemon was installed with an
    ///    administrator password rather than run from inside the bundle.
    /// 3: spent. A build carrying it was installed on the author's Mac while
    ///    the replacement was being proved, so a daemon out there answers 3
    ///    without the change that number was meant to name. Numbers are cheap;
    ///    a daemon that says it has something it has not is not.
    /// 4: NTFS is mounted with ntfs-3g rather than ntfs3. The mount script is
    ///    in LukottaCore, which the daemon links and runs, so the daemon is
    ///    the one that has to change -- a new script in the bundle reaches
    ///    nobody while the old daemon is still generating the old one.
    ///
    ///    That order was reverted the same day: the reading of the log that
    ///    prompted it was wrong, and ntfs3 leads again. The number is left
    ///    describing what it shipped as rather than what is true now, because
    ///    a daemon out there answers 4 and that is what it does.
    /// 5: the mount script joins driver options and read-only into one --options.
    ///    A daemon on 4 keeps generating two, which the engine refuses outright,
    ///    so a stale daemon does not merely mount differently: it cannot mount a
    ///    read-only NTFS volume at all.
    /// 6-11: spent. Every one of them was installed on the author's Mac while
    ///    this was being proved, so a daemon answering any of them does some
    ///    part of what 12 does and not the rest. The same reasoning as 3:
    ///    numbers are cheap, and a daemon that says it has something it has
    ///    not is not.
    /// 12: a long copy into a drive stops answering partway, and everything
    ///    below is what that turned out to need. The guest's NFS server runs
    ///    eight threads rather than one per CPU, so being busy writing is no
    ///    longer the same as being unable to answer. The transfer size is asked
    ///    for at the size that is granted, and the guest is told what size to
    ///    serve at, so it no longer follows from how much memory the machine
    ///    was given. The client waits sixty seconds for a slow server rather
    ///    than ten, and the mount is allowed fifteen minutes of silence rather
    ///    than five -- the second dominates the first, so raising one without
    ///    the other changed nothing. Every mount carries `noowners`. A volume
    ///    Windows left dirty is repaired and mounted writable rather than
    ///    demoted, unless it is hibernated or fails a dry run, in which case it
    ///    is still opened read-only. A LUKS machine is sized from the volume's
    ///    own header instead of a flat 2560 MiB.
    ///
    ///    A daemon on 5 -- which is what the pre-release carries -- generates a
    ///    script with none of it.
    /// 13 adds `mutejukebox` to the mount, which keeps a slow drive out of the
    /// list macOS builds its "server is not responding" dialog from. A daemon
    /// on 12 generates a mount without it, and the difference is a dialog on
    /// somebody's screen during a copy that is going perfectly well.
    ///
    /// Raised because the binary comparison does not cover a daemon this app
    /// registers itself: `installedToolIsStale` answers false the moment there
    /// is no job in /Library. The build comparison added beside it should have
    /// caught this one and did not, on a daemon twenty minutes older than the
    /// bundle -- so the number does the work here, which is what it is for.
    /// 14: ntfs3 is asked to mount read-only before it is trusted to mount
    ///    writable, and the two NTFS guest actions are generated together. The
    ///    mount script lives in LukottaCore, which the daemon links and runs,
    ///    so a daemon on 13 keeps generating the old script no matter what is
    ///    in the bundle -- which is exactly what happened while this was being
    ///    measured: three rebuilds in a row were served by a daemon from before
    ///    the first of them, and every result came from code that was no longer
    ///    on disk. The number is what makes the daemon notice.
    /// 16: a writable mount has to come back writable. ntfs-3g demotes itself
    ///    to read-only on a dirty volume and exits 0, so the chain stopped at
    ///    that rung and the repair below it never ran -- a drive handed back
    ///    read-only with no repair attempted. The check lives in the mount
    ///    script, which the daemon generates, so the daemon is what has to
    ///    change.
    public static let contract = 26

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

    /// Where the application carries the daemon it wants installed.
    public static func bundledToolPath(inBundle bundle: String) -> String {
        "\(bundle)/Contents/Library/LaunchServices/\(machServiceName)"
    }

    /// Whether the daemon on disk is the one this application carries.
    ///
    /// The contract number above is raised by hand, and the note against 4
    /// records what that costs: it shipped naming a change that was reverted
    /// the same day, so a daemon answering 4 does something the number does
    /// not describe. A number somebody must remember to raise is a number
    /// somebody will forget to raise, and the failure is silent in the worst
    /// way -- launchd keeps the running daemon across an update, so the
    /// application is new, the daemon is old, the mount is built the old way,
    /// and nothing anywhere says so. That is not a fault to be found by
    /// noticing; it has to be impossible.
    ///
    /// So the two binaries are compared instead of trusting either to describe
    /// itself. The daemon replaces itself without a password now, which is the
    /// whole reason the number was worth keeping: matching on the build no
    /// longer costs anybody a password, so there is nothing left to trade.
    ///
    /// Unreadable, missing, or different all answer false. "Cannot prove it is
    /// the right one" and "is the wrong one" lead to the same place, and the
    /// safe place is replacing it.
    public static func installedToolIsCurrent(
        installed: String, bundled: String, fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.contents(atPath: bundled) != nil else { return false }
        guard let running = fileManager.contents(atPath: installed),
            let carried = fileManager.contents(atPath: bundled)
        else { return false }
        return running == carried
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

    /// What this daemon promises, as a number the app compares against
    /// `HelperInfo.contract`. A daemon too old to answer this is older than
    /// contract 2 by definition, and its error handler says so.
    func helperContract(reply: @escaping (Int) -> Void)

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

    /// Replace this daemon's own binary with the one in the application that
    /// is asking, and exit so launchd starts it.
    ///
    /// This is how a fix to the daemon reaches a Mac that already has one.
    /// SMJobBless copies the binary into /Library/PrivilegedHelperTools, and
    /// only root may write there -- so without this the only way across is
    /// another administrator password, on every update that changes the
    /// daemon, for ever. It is already root; it does not need permission to
    /// replace itself.
    ///
    /// The binary is taken from the caller's own code signature, never from a
    /// path it sends, and is refused unless it satisfies the same requirement
    /// this daemon admits callers by.
    func refreshYourself(reply: @escaping (Bool) -> Void)

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
