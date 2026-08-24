// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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

        /// Mount the filesystem read-only, and export it read-only.
        ///
        /// Both sides are set. `-o ro` makes the mount inside the guest
        /// read-only, and `ro` among the NFS options makes the host's own mount
        /// read-only, which is the half Finder reads. A volume Windows left
        /// dirty also mounts this way where read-write is refused.
        var readOnly = false

        /// macOS negotiates 32 KiB NFS transfers by default and supports 1 MiB,
        /// which matters for sequential throughput over this loopback mount.
        var nfsOptions = "rsize=1048576,wsize=1048576,readahead=128"

        public init(
            enginePath: String, devicePath: String, driveName: String,
            kind: VolumeKind, volume: LogicalVolume? = nil,
            aliasPath: String? = nil, fifoPath: String, logPath: String,
            discoverLogPath: String, expectScriptPath: String,
            configPath: String, libraryPaths: [String], uid: UInt32, gid: UInt32,
            cores: Int, ramMiB: Int, elevated: Bool = true, readOnly: Bool = false
        ) {
            self.enginePath = enginePath
            self.devicePath = devicePath
            self.driveName = driveName
            self.kind = kind
            self.volume = volume
            self.aliasPath = aliasPath
            self.fifoPath = fifoPath
            self.logPath = logPath
            self.discoverLogPath = discoverLogPath
            self.expectScriptPath = expectScriptPath
            self.configPath = configPath
            self.libraryPaths = libraryPaths
            self.uid = uid
            self.gid = gid
            self.cores = cores
            self.ramMiB = ramMiB
            self.elevated = elevated
            self.readOnly = readOnly
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

    /// How many volumes a container held, when not all of them opened.
    ///
    /// Nil when they all opened, when nothing said, and when the container held
    /// a single volume: the sentence this feeds says "volumes", with no plural
    /// variation in any language it is translated into, so one volume that
    /// failed to open read as "This drive holds 1 volumes".
    public static func volumeShortfall(in transcript: String) -> Int? {
        guard
            let line = transcript.components(separatedBy: .newlines)
                .last(where: { $0.contains(volumesMarker) }),
            let tail = line.components(separatedBy: volumesMarker).last
        else { return nil }
        let parts = tail.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let opened = Int(parts[0]), let total = Int(parts[1]),
            total > opened, total >= 2
        else { return nil }
        return total
    }

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

        // The script is generated, so it has no version of its own to read
        // unless it says one. It writes the engine's log, and a log line means
        // different things either side of a change to the script that produced
        // it -- so the version that wrote it is in the file, and in the report.
        var lines: [String] = [
            "#!/bin/sh", "# lukotta mount script v\(Components.mountScriptVersion)",
        ]

        // DYLD_* must be set inside the elevated shell: macOS strips those
        // variables across a privilege boundary.
        let libs = i.libraryPaths.joined(separator: ":")
        if !libs.isEmpty {
            lines.append("export DYLD_LIBRARY_PATH=\(shellQuoted(libs))")
            lines.append("export DYLD_FALLBACK_LIBRARY_PATH=\(shellQuoted(libs))")
        }

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
        // The baseline every attempt is judged against: which mounts the
        // engine had before this one started, by name.
        lines.append(mountHelpers(baselineQ: shellQuoted(i.discoverLogPath + ".mounts")))
        lines.append("__rebase")

        var chain = attempts(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ)

        // A drive that will not mount read-write often mounts read-only: a
        // volume Windows left hibernated, a card with its write-protect switch
        // set, an image file on a read-only volume, or a filesystem whose log
        // needs replaying before it can be written to. Where read-write was
        // asked for and every attempt at it failed, the same attempts are made
        // again read-only rather than reporting a drive that cannot be opened.
        //
        // The marker says which happened, so the drive is never presented as
        // writable when it is not.
        if !i.readOnly {
            var readOnly = i
            readOnly.readOnly = true
            let retry = attempts(readOnly, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ)
            // The echo sits inside the braces, with the attempt it belongs
            // to. Outside them it would be a separate element of the chain:
            // `||` and `&&` are of equal precedence in the shell and group
            // left to right, so `a || { b ; } && echo m` runs the echo when
            // `a` succeeded, and every writable mount would report itself as
            // read-only.
            chain += retry.map {
                "{ \($0) && echo \"\(stageMarker)read-only\" >> \(logQ) ; }"
            }
        }
        lines.append(chain.joined(separator: " || "))
        lines.append("__rc=$?")
        // Mark the host's own mount read-only, which is the half Finder reads.
        //
        // The engine will not be asked for a read-only export and given
        // --ignore-permissions in the same breath, so read-only is carried by
        // the export options and by the guest's own mount. Both of those are
        // behind the NFS server: the volume arrives here presented as writable,
        // Finder offers to write to it, and the refusal comes at the moment
        // something is written rather than when it is opened.
        //
        // Updating the mount afterwards says it in the one place Finder looks.
        // Tolerant of failure: a mount that will not take the flag is the
        // volume as it was, refusing writes a moment later than it might have.
        let readOnlyAgain = """
            __read_only() {
              __new_mounts | while read -r __p; do
                [ -n "$__p" ] && /sbin/mount -u -o ro "$__p" >/dev/null 2>&1 || true
              done
            }
            """
        lines.append(readOnlyAgain)
        if i.readOnly {
            lines.append("[ \"$__rc\" = 0 ] && __read_only")
        } else {
            // Only where the read-write attempts failed and the fallback took
            // it read-only, which is what the marker records.
            lines.append(
                "[ \"$__rc\" = 0 ] && grep -q \"\(stageMarker)read-only\" \(logQ) 2>/dev/null "
                    + "&& __read_only")
        }
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
                    driver: nil, options: nfsOptions(i), readOnly: i.readOnly,
                    ownership: ownershipFlags(i), logQ: logQ)
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
                    options: nfsOptions(i), readOnly: i.readOnly,
                    ownership: ownershipFlags(i), logQ: logQ)
            }
        }
        if i.kind == .linux {
            result.append(discovery(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ))
        }
        return result
    }

    /// The shell functions every attempt is judged by.
    ///
    /// Which mounts the engine has, by name, rather than how many there are.
    /// A count is a count of everything: an NFS share the person using the Mac
    /// mounted themselves, whose server path happens to contain /mnt/ or /run/,
    /// joins the baseline, and one that comes or goes while a drive is being
    /// opened moves the number without any drive having been opened. Since the
    /// count is the only proof a mount worked — the engine exits 0 either way —
    /// that showed up as a drive that had opened being reported as a failure,
    /// or the reverse.
    ///
    /// Comparing the names cannot be moved by anybody else's mount: what is
    /// looked for is a mount point that was not there before.
    private static func mountHelpers(baselineQ: String) -> String {
        return """
            __engine_mounts() {
              /sbin/mount | awk '/\\(nfs/ && /:\\/(mnt|run)\\// \
                { sub(/^.* on /, ""); sub(/ \\(.*$/, ""); print }' | sort
            }
            __rebase() { __engine_mounts > \(baselineQ); }
            __new_mounts() { __engine_mounts | grep -vxF -f \(baselineQ) || true; }
            __mounted() { [ -n "$(__new_mounts)" ]; }
            """
    }

    /// Proof that a mount actually happened.
    ///
    /// The engine exits 0 when a mount fails, reporting the status of its own
    /// orderly shutdown rather than of the mount. Every fallback here is chained
    /// with `||`, so without this the shell treated the first attempt as
    /// successful and ran none of them: no ntfs-3g retry for a dirty volume, and
    /// no LVM discovery for a container holding several volumes.
    ///
    /// Mounts are compared by name rather than matched against an expected one.
    /// The share is named after the device for a plain volume and after the
    /// volume group for an LVM one ("lvm-fedoravg.local:"), so there is no
    /// single name to look for and a wrong guess reports a mounted drive as a
    /// failure.
    private static let mountedCheck = "__mounted"

    private static func mountCommand(
        engineQ: String,
        target: String,
        driver: String?,
        options: String,
        readOnly: Bool,
        ownership: String,
        logQ: String
    ) -> String {
        let typeFlag = driver.map { " -t \($0)" } ?? ""
        // --nfs-options must use the joined form. The flag is variadic, and the
        // separated form consumes the target that follows it.
        return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount\(ownership)"
            + "\(typeFlag)\(readOnlyFlags(readOnly)) -w false"
            + " --nfs-options=\(shellQuoted(options))"
            + " \(target) >> \(logQ) 2>&1 && \(mountedCheck)"
    }

    /// How the mount is asked for: who the files belong to, and whether
    /// anything may be written.
    ///
    /// `--ignore-permissions` is what makes the files appear to belong to
    /// whoever opened the drive. The engine implements it by taking charge of
    /// the NFS export, which is also what it must do to export read-only -- so
    /// it refuses the two together, and every read-only mount of a real drive
    /// failed before the machine started:
    ///
    ///     error: the argument '--ignore-permissions' cannot be used with
    ///            '--nfs-export-opts <NFS_EXPORT_OPTS>'
    ///
    /// A read-only mount therefore says both things in the one flag the engine
    /// will accept: the export is read-only, and every file in it is reported
    /// as belonging to the user, which is what --ignore-permissions was for.
    /// The other options are the engine's own defaults, kept because naming
    /// the export at all replaces them.
    static func ownershipFlags(_ i: Inputs) -> String {
        guard i.readOnly else { return " --ignore-permissions" }
        let opts =
            "ro,no_subtree_check,no_root_squash,insecure,"
            + "all_squash,anonuid=\(i.uid),anongid=\(i.gid)"
        return " --nfs-export-opts=" + shellQuoted(opts)
    }

    /// What makes the mount inside the guest read-only.
    ///
    /// The host side is done separately, through the NFS options, because the
    /// engine refuses `--nfs-export-opts` together with `--ignore-permissions`:
    /// "the argument '--ignore-permissions' cannot be used with
    /// '--nfs-export-opts'". Overriding the export would also discard what
    /// `--ignore-permissions` sets, which is what makes the files readable by
    /// the person who opened the drive.
    static func readOnlyFlags(_ readOnly: Bool) -> String {
        // Not a ternary of two literals: the string extractor reads both halves
        // of one as text shown to someone, and these are engine flags.
        guard readOnly else { return "" }
        return " -o ro"
    }

    /// What each volume of a container is mounted with inside the guest.
    ///
    /// Written as a guard rather than a ternary of two literals, which the
    /// string extractor reads as text shown to someone.
    static func perVolumeOptions(_ i: Inputs) -> String {
        guard i.readOnly else { return "" }
        return "-o ro "
    }

    /// The NFS options for a mount, with `ro` added when it is read-only.
    ///
    /// This is the half Finder sees. Without it the volume is presented as
    /// writable and a write fails with "Permission denied" at the moment it is
    /// attempted; with it the volume is read-only in the mount table, Finder
    /// marks it so, and a write fails as "Read-only file system".
    static func nfsOptions(_ i: Inputs) -> String {
        // Deliberately the same either way.
        //
        // Adding "ro" here asks the engine for a read-only NFS export, and on
        // the privileged route it answers by building --nfs-export-opts for
        // itself -- then refuses that flag alongside --ignore-permissions,
        // which is its own rule and ours to keep out of: "the argument
        // '--ignore-permissions' cannot be used with '--nfs-export-opts'". So
        // every read-only mount of a real drive failed before the machine
        // started, four times over, and the same mount succeeded unprivileged
        // where the engine takes another path.
        //
        // Read-only is carried by "-o ro" instead, which is the guest's own
        // mount and the half that decides whether anything can be written. The
        // host mount is then presented as writable and a write is refused when
        // it is attempted rather than when it is asked for, which is the
        // smaller of the two wrongs.
        i.nfsOptions
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
                echo "\(volumesMarker)$(__new_mounts | grep -c .):$__count" >> \(logQ)
              else
                __opened=0
                for __lv in $__lvs; do
                  ALFS_PASSPHRASE="$__cred" \(engineQ) mount\(ownershipFlags(i))\(readOnlyFlags(i.readOnly)) -w false --nfs-options=\(shellQuoted(nfsOptions(i))) "lvm:$__lv" >> \(logQ) 2>&1
                  if __mounted; then
                    __opened=$((__opened+1))
                    __rebase
                  fi
                done
                echo "\(volumesMarker)$__opened:$__count" >> \(logQ)
                [ "$__opened" -gt 0 ]
              fi
            }
            """
    }

    /// The awk that turns the engine's volume listing into a custom action.
    ///
    /// Public so that a test can run it — with `awk -v s=… -v q="'" -v ro=…` —
    /// over a captured listing. It is the only reader of that listing that
    /// decides what gets mounted, and there is no way to check it from the
    /// generated script as a whole.
    public static let volumeAction = """
        \(lvRow) {
          n++
          lv = $NF; sub(/^.*:/, "", lv)
          vg = $NF; sub(/:.*/, "", vg)
          name = ""
          for (f = 3; f <= lastNameField(); f++) name = name (f > 3 ? "-" : "") $f
          gsub(/[^A-Za-z0-9._-]/, "-", name)
          sub(/^[-.]+/, "", name)
          if (name == "") name = lv
          if (seen[name]++) name = name "-" seen[name]
          names[n] = name; lvs[n] = lv; vgs[n] = vg
        }
        # Where the name ends. The size is printed as a number and a unit today
        # ("608.2 MB"), and the name was taken as everything up to three fields
        # from the end on that basis alone. A size printed as one field would
        # have shifted every name by one and swallowed the type. So the unit is
        # looked for instead of counted on.
        function lastNameField() {
          return ($(NF - 1) ~ /^[KMGTPEZ]?i?[Bb]$/) ? NF - 3 : NF - 2
        }
        END {
          cmd = "set -eu; mkdir -p " s "; mount -t tmpfs -o size=1m tmpfs " s "; mkdir"
          for (f = 1; f <= n; f++) cmd = cmd " " s "/" names[f]
          cmd = cmd "; mount -o bind \\"$ALFS_VM_MOUNT_POINT\\" " s "/" names[1]
          # The primary volume is bound from the mount the engine made, so it is
          # already read-only when that one is. The rest are mounted here and
          # must say so.
          #
          # No apostrophes in here: the awk program is single-quoted, and one
          # would close the quote and break the script.
          for (f = 2; f <= n; f++)
            cmd = cmd "; mount " ro "/dev/" vgs[f] "/" lvs[f] " " s "/" names[f]
          # A read-only filesystem, not read-only permissions: the export
          # ignores permissions by design, so a mode of 555 was obeyed by nobody
          # and a file copied here still vanished on eject. One megabyte, so it
          # cannot pretend to hold anything either.
          cmd = cmd "; mount -o remount,ro " s
          subs = ""
          for (f = 1; f <= n; f++) subs = subs (f > 1 ? ", " : "") "\\"" names[f] "\\""
          print "[custom_actions.\(generatedAction)]"
          print "description = " q "Generated by Lukotta; removed after ejecting" q
          print "after_mount = " q cmd q
          print "override_nfs_export = " q s q
          print "nfs_export_subdirs = [" subs "]"
        }
        """

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
                awk -v s='\(scratch)' -v q="'" -v ro='\(perVolumeOptions(i))' '\(volumeAction)' \(listQ) > \(actionQ)
                # Merge, never replace: the config also holds the user's own
                # settings, and the engine rewrites it wholesale on every run.
                # Truncating in place keeps whoever owns the file owning it.
                { awk 'BEGIN { skip = 0 }
                       /^\\[/ { skip = ($0 == "[custom_actions.\(generatedAction)]") }
                       !skip' \(configQ) 2>/dev/null; cat \(actionQ); } > \(mergedQ)
                cat \(mergedQ) > \(configQ)
                __first=$(printf '%s\\n' "$__lvs" | head -n 1)
                ALFS_PASSPHRASE="$__cred" \(engineQ) mount\(ownershipFlags(i))\(readOnlyFlags(i.readOnly)) -w false --nfs-options=\(shellQuoted(nfsOptions(i))) -a \(generatedAction) "lvm:$__first" >> \(logQ) 2>&1
            """
    }
}
