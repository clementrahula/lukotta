import Foundation

/// Builds the shell script that runs, as root, to unlock and mount a drive.
///
/// Deliberately separate from executing it. This is the highest-risk text in
/// the application — it becomes a command run with full privileges — and both
/// production-breaking bugs so far were malformed arguments here:
///
///   * `-n <options> <device>` — the flag is variadic, so it consumed the
///     device path and the engine reported "mount with no disk".
///   * `--decrypt all <image>` — the same trap, hit earlier and then repeated.
///
/// Neither was reachable by a test while generation and execution were fused
/// into one function. Keeping this pure means the exact text can be asserted.
public enum MountScript {

    public struct Inputs {
        var enginePath: String
        var devicePath: String
        var driveName: String
        var kind: VolumeKind
        /// Set once the user has chosen among several logical volumes.
        var volume: LogicalVolume?
        /// Symlink named after the drive, so Finder shows that rather than
        /// "disk4s1.local". Optional: the real device path is always tried too.
        var aliasPath: String?
        var fifoPath: String
        var logPath: String
        var discoverLogPath: String
        var expectScriptPath: String
        var libraryPaths: [String]
        var uid: UInt32
        var gid: UInt32
        var cores: Int
        var ramMiB: Int

        /// macOS negotiates 32 KiB NFS transfers by default and supports 1 MiB,
        /// which matters for sequential throughput over this loopback mount.
        var nfsOptions = "rsize=1048576,wsize=1048576,readahead=128"

        public init(
            enginePath: String, devicePath: String, driveName: String,
            kind: VolumeKind, volume: LogicalVolume? = nil,
            aliasPath: String? = nil, fifoPath: String, logPath: String,
            discoverLogPath: String, expectScriptPath: String,
            libraryPaths: [String], uid: UInt32, gid: UInt32,
            cores: Int, ramMiB: Int
        ) {
            self.enginePath = enginePath; self.devicePath = devicePath
            self.driveName = driveName; self.kind = kind
            self.volume = volume; self.aliasPath = aliasPath
            self.fifoPath = fifoPath; self.logPath = logPath
            self.discoverLogPath = discoverLogPath
            self.expectScriptPath = expectScriptPath
            self.libraryPaths = libraryPaths
            self.uid = uid; self.gid = gid
            self.cores = cores; self.ramMiB = ramMiB
        }
    }

    /// Prefix for stage markers the script writes as it progresses.
    ///
    /// The engine emits very little while mounting, so progress cannot be
    /// inferred from its output. These are written by the script itself, at
    /// points where something has definitely happened.
    public static let stageMarker = "LUKOTTA_STAGE:"

    /// Marker written when a container holds several volumes and the engine was
    /// therefore never told which to mount.
    public static let multipleVolumesMarker = "LUKOTTA_MULTIPLE_VOLUMES"
    /// How many of a container's volumes opened, of how many were found.
    public static let volumesMarker = "LUKOTTA_VOLUMES:"

    /// Drives the engine's interactive passphrase prompt.
    ///
    /// `list --decrypt` prompts on a terminal and ignores ALFS_PASSPHRASE, so it
    /// has to be fed through a pty. `expect -c` keeps reading commands from
    /// stdin once an inline script ends and never exits, so this must be a file.
    public static let expectDriver = """
        set timeout 600
        spawn -noecho [lindex $argv 0] list --decrypt=all [lindex $argv 1]
        expect {
          -re "passphrase.*: " { send "$env(ALFS_PASSPHRASE)\\r"; exp_continue }
          timeout { exit 99 }
          eof
        }
        catch wait result
        exit [lindex $result 3]
        """

    public static func build(_ i: Inputs) -> String {
        let engineQ = shellQuoted(i.enginePath)
        let deviceQ = shellQuoted(i.devicePath)
        let logQ = shellQuoted(i.logPath)

        var lines: [String] = ["#!/bin/sh"]

        // DYLD_* must be set inside the elevated shell: macOS strips those
        // variables across a privilege boundary.
        let libs = i.libraryPaths.joined(separator: ":")
        if !libs.isEmpty {
            lines.append("export DYLD_LIBRARY_PATH=\(shellQuoted(libs))")
            lines.append("export DYLD_FALLBACK_LIBRARY_PATH=\(shellQuoted(libs))")
        }

        // `do shell script … with administrator privileges` runs the command
        // directly as root rather than through sudo, so these are absent and the
        // engine refuses to start with "must not be run directly by root".
        lines.append("export SUDO_UID=\(i.uid)")
        lines.append("export SUDO_GID=\(i.gid)")

        // Read the credential from the pipe once into a variable: a FIFO can
        // only be consumed once, and re-prompting per attempt would defeat the
        // single authorisation.
        // Reaching this line means authorisation succeeded and the script is
        // running as root.
        lines.append("echo \"\(stageMarker)authorised\" >> \(logQ)")
        lines.append("__cred=\"$(cat \(shellQuoted(i.fifoPath)))\"")
        lines.append("echo \"\(stageMarker)working\" >> \(logQ)")
        lines.append("\(engineQ) config -n \(i.cores) -r \(i.ramMiB) >/dev/null 2>&1 || true")
        // The baseline every attempt is judged against.
        lines.append("__mounts=$(\(mountCount))")

        lines.append(
            attempts(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ)
                .joined(separator: " || "))
        lines.append("__rc=$?")
        lines.append("unset __cred")
        lines.append("exit $__rc")
        return lines.joined(separator: "\n")
    }

    private static func attempts(
        _ i: Inputs,
        engineQ: String,
        deviceQ: String,
        logQ: String
    ) -> [String] {
        // A volume already chosen by the user is mounted directly: no driver
        // override, no discovery.
        if let volume = i.volume {
            return [
                mountCommand(
                    engineQ: engineQ,
                    target: shellQuoted(volume.mountIdentifier),
                    driver: nil, options: i.nfsOptions, logQ: logQ)
            ]
        }

        // ntfs3 is the in-kernel driver and much faster, but refuses a "dirty"
        // volume — which is what Windows Fast Startup and hibernation leave
        // behind. ntfs-3g mounts those. A Linux volume gets no override, so the
        // engine detects ext4, btrfs or xfs itself.
        let drivers: [String?] = i.kind == .microsoft ? ["ntfs3", "ntfs-3g"] : [nil]
        // The engine resolves whatever target it is handed by prefixing /dev/,
        // so an alias living anywhere else can never resolve — it only produced
        // a "disk /dev//var/folders/… not found" line ahead of every mount.
        let alias = i.aliasPath.flatMap { $0.hasPrefix("/dev/") ? $0 : nil }
        let targets = [alias.map(shellQuoted), deviceQ].compactMap { $0 }

        var result = targets.flatMap { target in
            drivers.map {
                mountCommand(
                    engineQ: engineQ, target: target, driver: $0,
                    options: i.nfsOptions, logQ: logQ)
            }
        }
        if i.kind == .linux {
            result.append(discovery(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ))
        }
        return result
    }

    /// How many mounts the engine currently has, by its export path.
    private static let mountCount = "/sbin/mount | grep -c ':/mnt/'"

    /// Proof that a mount actually happened.
    ///
    /// The engine exits 0 when a mount fails — it reports the status of its own
    /// orderly shutdown, not of the mount. Every fallback here is chained with
    /// `||`, so without this the shell saw the first attempt succeed and ran
    /// none of them: no ntfs-3g retry for a dirty volume, and no LVM discovery
    /// for a container holding several volumes.
    ///
    /// Counting rather than matching a name: the share is named after the
    /// device for a plain volume but after the volume group for an LVM one
    /// ("lvm-fedoravg.local:"), so there is no one name to look for, and
    /// guessing wrong reports a mounted drive as a failure.
    private static let mountedCheck = "[ \"$(\(mountCount))\" -gt \"$__mounts\" ]"

    private static func mountCommand(
        engineQ: String,
        target: String,
        driver: String?,
        options: String,
        logQ: String
    ) -> String {
        let typeFlag = driver.map { " -t \($0)" } ?? ""
        // --nfs-options MUST use the joined form: the flag is variadic, and the
        // separated form swallows the target that follows it.
        return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount --ignore-permissions"
            + "\(typeFlag) -w false --nfs-options=\(shellQuoted(options))"
            + " \(target) >> \(logQ) 2>&1 && \(mountedCheck)"
    }

    /// Ubuntu, Debian, Mint and Fedora all put LVM inside the LUKS container,
    /// so unlocking exposes a volume group rather than a filesystem.
    private static func discovery(
        _ i: Inputs,
        engineQ: String,
        deviceQ: String,
        logQ: String
    ) -> String {
        let listQ = shellQuoted(i.discoverLogPath)
        return """
            {
              ALFS_PASSPHRASE="$__cred" /usr/bin/expect -f \(shellQuoted(i.expectScriptPath)) \(engineQ) \(deviceQ) > \(listQ) 2>&1
              # expect drives the engine through a pty, so every line comes back
              # CRLF. awk splits on newlines only, which leaves the carriage
              # return stuck to the last field: the identifier becomes
              # "vg:disk:lv\\r" and names a block device that cannot exist.
              tr -d '\\r' < \(listQ) > \(listQ).clean && mv \(listQ).clean \(listQ)
              cat \(listQ) >> \(logQ)
              __lvs=$(awk '$NF ~ /^[^:]+:[^:]+:[^:]+$/ && $2 != "LVM2_scheme" { print $NF }' \(listQ))
              __count=$(printf '%s\\n' "$__lvs" | grep -c . )
              __opened=0
              for __lv in $__lvs; do
                ALFS_PASSPHRASE="$__cred" \(engineQ) mount --ignore-permissions -w false --nfs-options=\(shellQuoted(i.nfsOptions)) "lvm:$__lv" >> \(logQ) 2>&1
                __now=$(\(mountCount))
                if [ "$__now" -gt "$__mounts" ]; then
                  __opened=$((__opened+1))
                  __mounts=$__now
                fi
              done
              echo "\(volumesMarker)$__opened:$__count" >> \(logQ)
              [ "$__opened" -gt 0 ]
            }
            """
    }
}
