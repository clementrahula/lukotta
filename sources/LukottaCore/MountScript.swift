import Foundation

/// Builds the shell script that runs, as root, to unlock and mount a drive.
///
/// Kept separate from executing it. The text becomes a command run with full
/// privileges, and the failures it invites are malformed arguments: the engine's
/// `-n` and `--decrypt` flags are variadic, so a value placed after one is
/// consumed by it and the device path never arrives.
///
/// A test can reach none of that while generation and execution are one
/// function. Generating the text separately means the exact text can be
/// asserted.
public enum MountScript {

    public struct Inputs {
        var enginePath: String
        var devicePath: String
        var driveName: String
        var kind: VolumeKind
        /// A single volume to mount directly, skipping discovery. Nothing sets
        /// one, since every volume of a container is opened, but the helper's
        /// XPC method still carries the parameter. Renaming that selector would
        /// leave a freshly updated app calling a still-running older helper that
        /// never answers.
        var volume: LogicalVolume?
        /// Symlink named after the drive, so Finder shows that rather than
        /// "disk4s1.local". Optional: the real device path is always tried too.
        var aliasPath: String?
        var fifoPath: String
        var logPath: String
        var discoverLogPath: String
        var expectScriptPath: String
        /// The engine's config.toml. A container holding several volumes is
        /// served through a custom action generated into this file.
        var configPath: String
        var libraryPaths: [String]
        var uid: UInt32
        var gid: UInt32
        var cores: Int
        var ramMiB: Int
        /// Whether the script will be run as root. A container file attached by
        /// this user needs no privilege at all.
        var elevated = true

        /// macOS negotiates 32 KiB NFS transfers by default and supports 1 MiB,
        /// which matters for sequential throughput over this loopback mount.
        var nfsOptions = "rsize=1048576,wsize=1048576,readahead=128"

        public init(
            enginePath: String, devicePath: String, driveName: String,
            kind: VolumeKind, volume: LogicalVolume? = nil,
            aliasPath: String? = nil, fifoPath: String, logPath: String,
            discoverLogPath: String, expectScriptPath: String,
            configPath: String, libraryPaths: [String], uid: UInt32, gid: UInt32,
            cores: Int, ramMiB: Int, elevated: Bool = true
        ) {
            self.enginePath = enginePath; self.devicePath = devicePath
            self.driveName = driveName; self.kind = kind
            self.volume = volume; self.aliasPath = aliasPath
            self.fifoPath = fifoPath; self.logPath = logPath
            self.discoverLogPath = discoverLogPath
            self.expectScriptPath = expectScriptPath
            self.configPath = configPath
            self.libraryPaths = libraryPaths
            self.uid = uid; self.gid = gid
            self.cores = cores; self.ramMiB = ramMiB
            self.elevated = elevated
        }
    }

    /// Prefix for stage markers the script writes as it progresses.
    ///
    /// The engine emits very little while mounting, so progress cannot be
    /// inferred from its output. These are written by the script itself, at
    /// points where something has definitely happened.
    public static let stageMarker = "LUKOTTA_STAGE:"

    /// How many of a container's volumes opened, of how many were found.
    public static let volumesMarker = "LUKOTTA_VOLUMES:"

    /// How large a machine to give a mount.
    ///
    /// The machine unlocks a filesystem and serves it over NFS, which needs
    /// little. libkrun backs guest memory lazily, so an inflated figure is
    /// invisible in Activity Monitor and still harmful: the scratch directory a
    /// container's volumes are served from is sized from it, and a larger figure
    /// reports free space that does not exist.
    public enum VirtualMachine {
        public static let ramMiB = 1024
        /// Half the machine and never more than two, the work being I/O.
        public static var cores: Int {
            max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        }
    }

    /// Name of the custom action generated into the engine's config.toml. A
    /// constant rather than one name per drive: the engine reads it only at
    /// mount time, so each mount overwrites it and cleanup has one name to
    /// remove.
    public static let generatedAction = "lukotta"

    /// The guest-side scratch directory's name, which is also the drive's name
    /// in Finder, the engine deriving the mount point from the last component of
    /// the exported path.
    ///
    /// Restricted to characters that are safe unquoted in a shell command, in a
    /// TOML literal string, and in the engine's NFS-export markers, because the
    /// name is embedded in all three.
    public static func exportName(driveName: String, devicePath: String) -> String {
        let fromDrive = sanitised(driveName)
        if !fromDrive.isEmpty { return fromDrive }
        let fromDevice = sanitised(URL(fileURLWithPath: devicePath).lastPathComponent)
        return fromDevice.isEmpty ? "Volumes" : fromDevice
    }

    private static func sanitised(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let safe =
                ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "." || scalar == "_"
                || scalar == "-"
            out.append(safe ? Character(scalar) : "-")
        }
        // A leading dot hides the volume in Finder, and a leading dash reads as
        // a flag to any tool later handed the bare name.
        while let first = out.first, first == "." || first == "-" {
            out.removeFirst()
        }
        return String(out.prefix(40))
    }

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
        // Only when elevated. `do shell script ... with administrator
        // privileges` runs as root rather than through sudo, so SUDO_UID and
        // SUDO_GID are absent and the engine refuses to start ("must not be run
        // directly by root"). Supplying them names the real invoking user. When
        // the script already runs as that user they are wrong rather than
        // redundant, since the engine would then take itself for a sudo
        // session.
        if i.elevated {
            lines.append("export SUDO_UID=\(i.uid)")
            lines.append("export SUDO_GID=\(i.gid)")
        }

        // Read the credential from the pipe into a variable. A FIFO can be
        // consumed once, and prompting again per attempt would defeat the single
        // authorisation.
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

        // ntfs3 is the in-kernel driver and much faster, and refuses a volume
        // marked dirty, which is what Windows Fast Startup and hibernation
        // leave behind. ntfs-3g mounts those. A Linux volume gets no override,
        // so the engine detects ext4, btrfs or xfs itself.
        let drivers: [String?] = i.kind == .microsoft ? ["ntfs3", "ntfs-3g"] : [nil]
        // The engine resolves whatever target it is handed by prefixing /dev/,
        // so an alias elsewhere never resolves and produced a
        // "disk /dev//var/folders/… not found" line ahead of every mount.
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

    /// How many mounts the engine currently has, by its export path: /mnt for
    /// ordinary mounts, /run for the multi-volume scratch directory.
    private static let mountCount = "/sbin/mount | grep -cE ':/(mnt|run)/'"

    /// Proof that a mount actually happened.
    ///
    /// The engine exits 0 when a mount fails, reporting the status of its own
    /// orderly shutdown rather than of the mount. Every fallback here is chained
    /// with `||`, so without this the shell treated the first attempt as
    /// successful and ran none of them: no ntfs-3g retry for a dirty volume, and
    /// no LVM discovery for a container holding several volumes.
    ///
    /// Mounts are counted rather than matched by name. The share is named after
    /// the device for a plain volume and after the volume group for an LVM one
    /// ("lvm-fedoravg.local:"), so there is no single name to look for and a
    /// wrong guess reports a mounted drive as a failure.
    private static let mountedCheck = "[ \"$(\(mountCount))\" -gt \"$__mounts\" ]"

    private static func mountCommand(
        engineQ: String,
        target: String,
        driver: String?,
        options: String,
        logQ: String
    ) -> String {
        let typeFlag = driver.map { " -t \($0)" } ?? ""
        // --nfs-options must use the joined form. The flag is variadic, and the
        // separated form consumes the target that follows it.
        return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount --ignore-permissions"
            + "\(typeFlag) -w false --nfs-options=\(shellQuoted(options))"
            + " \(target) >> \(logQ) 2>&1 && \(mountedCheck)"
    }

    /// Rows of `list --decrypt=all` that are mountable logical volumes: an
    /// indexed row whose identifier is vg:disk:lv and whose type is an actual
    /// filesystem. This must agree with VolumeGroupParser's container list: the
    /// generated action mounts everything it matches, and one unmountable row
    /// fails the whole multi-volume mount.
    private static let lvRow =
        "$1 ~ /^[0-9]+:$/ && $NF ~ /^[^:]+:[^:]+:[^:]+$/"
        + " && $2 !~ /^(LVM2_scheme|LVM2_member|crypto_LUKS|swap|linux_raid_member)$/"

    /// Ubuntu, Debian, Mint and Fedora all put LVM inside the LUKS container,
    /// so unlocking exposes a volume group rather than a filesystem.
    ///
    /// Several volumes are served together from one microVM, which is a
    /// constraint rather than a convenience: the engine takes an exclusive lock
    /// on the device for a read-write mount, so a second VM on the same disk
    /// cannot start, and mounting each volume separately opened only the first.
    /// If the combined mount fails, the loop below falls back to opening one
    /// volume.
    private static func discovery(
        _ i: Inputs,
        engineQ: String,
        deviceQ: String,
        logQ: String
    ) -> String {
        let listQ = shellQuoted(i.discoverLogPath)
        let scratch = "/run/" + exportName(driveName: i.driveName, devicePath: i.devicePath)
        return """
            {
              ALFS_PASSPHRASE="$__cred" /usr/bin/expect -f \(shellQuoted(i.expectScriptPath)) \(engineQ) \(deviceQ) > \(listQ) 2>&1
              # expect drives the engine through a pty, so every line comes back
              # CRLF. awk splits on newlines only, which leaves the carriage
              # return stuck to the last field: the identifier becomes
              # "vg:disk:lv\\r" and names a block device that cannot exist.
              tr -d '\\r' < \(listQ) > \(listQ).clean && mv \(listQ).clean \(listQ)
              cat \(listQ) >> \(logQ)
              __lvs=$(awk '\(lvRow) { print $NF }' \(listQ))
              __count=$(printf '%s\\n' "$__lvs" | grep -c . )
              if [ "$__count" -gt 1 ]; then
            \(multiVolume(i, engineQ: engineQ, logQ: logQ, listQ: listQ, scratch: scratch))
              fi
              if \(mountedCheck); then
                echo "\(volumesMarker)$(/sbin/mount | grep -cF \(shellQuoted(":" + scratch + "/"))):$__count" >> \(logQ)
              else
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
              fi
            }
            """
    }

    /// Generate the custom action that serves every volume, and mount with it.
    ///
    /// Inside the VM every volume is already active under /dev/<vg>/<lv>, since
    /// `vgchange -ay` runs before any action, so the generated `after_mount`
    /// mounts each onto a scratch directory in the VM's own tmpfs and the engine
    /// NFS-exports them together: the primary at the mount point and the rest
    /// nested inside it.
    ///
    /// The scratch directory is what makes this safe. Mounting the extra volumes
    /// onto directories created inside the primary volume would write to the
    /// drive, and Lukotta does not modify a drive it opens.
    /// `override_nfs_export` points the export at /run instead, which is tmpfs
    /// and vanishes with the VM.
    private static func multiVolume(
        _ i: Inputs,
        engineQ: String,
        logQ: String,
        listQ: String,
        scratch: String
    ) -> String {
        let actionQ = shellQuoted(i.discoverLogPath + ".action")
        let mergedQ = shellQuoted(i.discoverLogPath + ".merged")
        let configQ = shellQuoted(i.configPath)
        // The engine substitutes $VARIABLES in action strings on the host and
        // aborts on any it does not know, so the generated command may use
        // $ALFS_VM_MOUNT_POINT and nothing else. Every other path is literal,
        // which exportName's character set makes safe unquoted.
        //
        // The per-volume directories are created read-only (555): should a
        // nested NFS mount ever fail on the host, the bare tmpfs stub under it
        // must not accept writes the user believes go to the drive.
        return """
                awk -v s='\(scratch)' -v q="'" '\(lvRow) {
                    n++
                    lv = $NF; sub(/^.*:/, "", lv)
                    vg = $NF; sub(/:.*/, "", vg)
                    name = ""
                    for (f = 3; f <= NF - 3; f++) name = name (f > 3 ? "-" : "") $f
                    gsub(/[^A-Za-z0-9._-]/, "-", name)
                    sub(/^[-.]+/, "", name)
                    if (name == "") name = lv
                    if (seen[name]++) name = name "-" seen[name]
                    names[n] = name; lvs[n] = lv; vgs[n] = vg
                  }
                  END {
                    cmd = "set -eu; mkdir -p " s "; mount -t tmpfs -o size=1m tmpfs " s "; mkdir"
                    for (f = 1; f <= n; f++) cmd = cmd " " s "/" names[f]
                    cmd = cmd "; mount -o bind \\"$ALFS_VM_MOUNT_POINT\\" " s "/" names[1]
                    for (f = 2; f <= n; f++)
                      cmd = cmd "; mount /dev/" vgs[f] "/" lvs[f] " " s "/" names[f]
                    # A read-only filesystem, not read-only permissions: the
                    # export ignores permissions by design, so a mode of 555 was
                    # obeyed by nobody and a file copied here still vanished on
                    # eject. One megabyte, so it cannot pretend to hold anything
                    # either.
                    cmd = cmd "; mount -o remount,ro " s
                    subs = ""
                    for (f = 1; f <= n; f++) subs = subs (f > 1 ? ", " : "") "\\"" names[f] "\\""
                    print "[custom_actions.\(generatedAction)]"
                    print "description = " q "Generated by Lukotta; removed after ejecting" q
                    print "after_mount = " q cmd q
                    print "override_nfs_export = " q s q
                    print "nfs_export_subdirs = [" subs "]"
                  }' \(listQ) > \(actionQ)
                # Merge, never replace: the config also holds the user's own
                # settings, and the engine rewrites it wholesale on every run.
                # Truncating in place keeps whoever owns the file owning it.
                { awk 'BEGIN { skip = 0 }
                       /^\\[/ { skip = ($0 == "[custom_actions.\(generatedAction)]") }
                       !skip' \(configQ) 2>/dev/null; cat \(actionQ); } > \(mergedQ)
                cat \(mergedQ) > \(configQ)
                __first=$(printf '%s\\n' "$__lvs" | head -n 1)
                ALFS_PASSPHRASE="$__cred" \(engineQ) mount --ignore-permissions -w false --nfs-options=\(shellQuoted(i.nfsOptions)) -a \(generatedAction) "lvm:$__first" >> \(logQ) 2>&1
            """
    }
}
