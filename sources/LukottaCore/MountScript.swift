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
        /// Where the engine keeps its image, its configuration and its logs.
        ///
        /// Passed in rather than resolved here: the helper composes the script
        /// while running as root, and anything it works out for itself lands in
        /// root's Library instead of the user's.
        var engineHome: String
        var libraryPaths: [String]
        var uid: UInt32
        var gid: UInt32
        var cores: Int
        var ramMiB: Int
        /// Whether the script will be run as root. A container file attached by
        /// this user needs no privilege at all.
        var elevated = true

        /// What the volume's own header says an unlock will allocate, in MiB.
        ///
        /// Nil where it could not be read, which is where the engine's own
        /// figure of 2560 stands: "cannot say" has to mean "keep the floor",
        /// because the failure of guessing low is an unlock killed for want of
        /// memory. See `LUKSHeader`.
        var luksMinRamMiB: Int?

        /// Mount the filesystem read-only, and export it read-only.
        ///
        /// Both sides are set. `-o ro` makes the mount inside the guest
        /// read-only, and `ro` among the NFS options makes the host's own mount
        /// read-only, which is the half Finder reads. A volume Windows left
        /// dirty also mounts this way where read-write is refused.
        var readOnly = false

        /// The transfer size is asked for at the size that is granted.
        ///
        /// Read off a live mount with `nfsstat -m`: the "original mount
        /// options" repeat what was asked for, and the "current mount
        /// parameters" -- what is actually in force -- say
        /// `rsize=131072,wsize=131072` however large a figure went in. Asking
        /// for a megabyte therefore set nothing and left the two disagreeing,
        /// and the client filled the system log with
        ///
        ///     nfs_buf_write_rpc: Got request with invalid length 0
        ///
        /// at about one per write RPC -- seventy thousand in a single
        /// thirteen-gigabyte copy, against six hundred once the numbers agree,
        /// with the socket resets and send failures alongside them gone too.
        ///
        /// `timeo` is sixty seconds because a healthy copy already spends
        /// twenty unable to answer.
        ///
        /// The engine's own default is `timeo=100,retrans=3` -- ten seconds a
        /// try, which with retries is a little over a minute of patience. That
        /// was measured against, rather than argued about: sampling
        /// `nfsstat -m` every two seconds through a thirteen-gigabyte copy into
        /// a USB drive, the mount was marked "not responding" ten separate
        /// times, for a mean of nine seconds and a longest of twenty-two, and
        /// recovered every time. Nothing was wrong on any of those occasions.
        /// The guest was writing.
        ///
        /// So the margin between a normal stall and a failed copy was about
        /// three times, and anything that widens the stall -- a fuller drive, a
        /// slower one, another volume open beside it -- spends it. When it is
        /// spent the copy stops with `error code 100060`, which is ETIMEDOUT
        /// wearing macOS's offset, and Finder throws away what it had written.
        ///
        /// Sixty seconds a try costs nothing while the server answers, because
        /// nothing waits for a timeout that does not happen.
        ///
        /// `deadtimeout` had to move with it. The older note here was right
        /// that it dominates: at 300 the mount is called dead after five
        /// minutes whatever `timeo` says, so raising the one without the other
        /// changed nothing and a copy still stopped. Fifteen minutes is long
        /// enough for a guest writing to a nearly-full drive to come back, and
        /// still finite -- a server that has genuinely gone is a soft mount
        /// returning errors either way.
        ///
        /// This is patience, not durability. Nothing here tells the server to
        /// acknowledge a write it has not made.
        ///
        /// `noowners` is the other half of what --ignore-permissions does, and
        /// the read-only route did not have it. The engine's own documentation
        /// gives the equivalent of that flag as
        /// `--nfs-export-opts rw,no_subtree_check,all_squash,anonuid=0,anongid=0,insecure`
        /// **and** `-n noowners`: the export squashes who is asking, and this
        /// stops macOS applying the ownership it is told about on top. Set for
        /// every mount because the writable route already gets it from the flag
        /// and cannot be given it twice.
        var nfsOptions =
            "rsize=\(MountScript.transferSize),wsize=\(MountScript.transferSize),"
            + "readahead=128,timeo=600,deadtimeout=900,noowners"

        /// Which network the microVM's NFS server is reached over.
        ///
        /// See `netHelper(forMajorVersion:)` for why this is decided by the
        /// version of macOS and not chosen once.
        var netHelper = MountScript.netHelper(
            forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

        public init(
            enginePath: String, devicePath: String, driveName: String,
            kind: VolumeKind, volume: LogicalVolume? = nil,
            aliasPath: String? = nil, fifoPath: String, logPath: String,
            discoverLogPath: String, expectScriptPath: String,
            configPath: String, engineHome: String, libraryPaths: [String], uid: UInt32,
            gid: UInt32,
            cores: Int, ramMiB: Int, elevated: Bool = true, readOnly: Bool = false,
            luksMinRamMiB: Int? = nil
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
            self.engineHome = engineHome
            self.libraryPaths = libraryPaths
            self.uid = uid
            self.gid = gid
            self.cores = cores
            self.ramMiB = ramMiB
            self.elevated = elevated
            self.readOnly = readOnly
            self.luksMinRamMiB = luksMinRamMiB
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
        /// 512 MiB, which is upstream's default and the floor a long copy needs.
        ///
        /// Upstream's figure for typical usage is 256, and a machine given
        /// exactly that fails a thirteen-gigabyte copy about three gigabytes
        /// in. What a guest holds beyond its working set is page cache, and
        /// page cache is what absorbs a burst of writes while a slow drive
        /// takes them. Starve it and the guest blocks on the drive instead,
        /// for longer than the client will wait, and the copy stops with
        /// error 100060.
        ///
        /// Measured rather than reasoned: 1024 completed the copy twice, 256
        /// failed, and a dirty-page bound at 1024 -- which starves the same
        /// cache by another route -- failed sooner still. 512 is upstream's
        /// own default and half what was proven; it is the number this is
        /// being tested at rather than a number anybody has proven yet.
        ///
        /// The figure is a ceiling rather than an allocation, libkrun backing
        /// guest memory lazily, but it is not free for being lazy: the scratch
        /// directory a container's volumes are served from is sized from it,
        /// so an inflated number reports free space that does not exist.
        ///
        /// This number cannot be raised much further, and that is the shape of
        /// a problem rather than a detail. Measured with one drive open and a
        /// copy running: 502 MB resident for the machine and its two helpers,
        /// against 170 MB when the guest was given 256 and about 1180 MB when
        /// it was given a gigabyte. Twelve drives open at once is therefore
        /// about 5.9 GB before macOS has taken anything, which an eight-
        /// gigabyte Mac does not have -- and this Mac was already down to
        /// 102 MB free with 4.4 GB compressed while serving one.
        ///
        /// So a copy that does not stall and a dozen drives open together are
        /// in direct conflict while every drive is its own machine, and no
        /// value here settles both. The way out is not a smaller number: it is
        /// one machine serving several drives. libkrun already attaches
        /// several disks to one VM -- `krun_add_disk2` is called in a loop --
        /// so the limit is the engine's model, one mount being one machine and
        /// one export, rather than anything underneath it.
        public static let ramMiB = 512
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
        // Where the engine keeps its image, its configuration and its logs.
        // Exported inside the elevated shell for the same reason DYLD_* is:
        // macOS strips the environment across a privilege boundary, and an
        // engine that does not see this looks in the shared home instead --
        // which is a different image, and may be another program's.
        lines.append("export \(EngineEnvironment.homeVariable)=\(shellQuoted(i.engineHome))")

        // What an unlock of this particular volume will allocate, read from its
        // header rather than assumed. The engine gives every LUKS mount 2560
        // MiB otherwise, which is a multiplier rather than a total when several
        // drives are open, and about eleven times what a default header asks
        // for. Exported inside the elevated shell for the same reason the rest
        // is: the environment does not survive the privilege boundary.
        if let floor = i.luksMinRamMiB {
            lines.append("export ALFS_LUKS_MIN_RAM_MIB=\(floor)")
        }

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
        // Read byte for byte, not through command substitution, which strips
        // every trailing newline: a passphrase ending in one -- legal, and
        // chosen by somebody who pasted it -- was silently altered on the way
        // to the engine, and refused with nothing to say why.
        lines.append("IFS= read -r -d '' __cred < \(shellQuoted(i.fifoPath)) || true")
        lines.append("echo \"\(stageMarker)working\" >> \(logQ)")
        // The script ends itself, a little before whoever is waiting on it
        // would. Left to the waiter, an attempt that will not finish is ended
        // by killing the shell -- and on the privileged route that shell is
        // root's, started through `do shell script`, so nothing the app can
        // signal belongs to it. The engine goes on working, and a drive appears
        // in Finder minutes after somebody has been told it could not be
        // opened, mounted by nothing that will ever eject it.
        //
        // Ending here instead means the shell that started the engine is the
        // one that stops it: same privilege, no orphan, and a real exit status
        // and transcript for the app to read.
        lines.append(watchdog(seconds: Int(TransientFailure.deadline) - 45, logQ: logQ))
        lines.append("\(engineQ) config -n \(i.cores) -r \(i.ramMiB) >/dev/null 2>&1 || true")
        // The baseline every attempt is judged against: which mounts the
        // engine had before this one started, by name.
        lines.append(
            mountHelpers(
                baselineQ: shellQuoted(i.discoverLogPath + ".mounts"),
                root: mountRoot(elevated: i.elevated)))
        lines.append("__rebase")
        lines.append(
            guestKernelHelpers(
                stampQ: shellQuoted(i.discoverLogPath + ".kstamp"),
                logQ: logQ))
        lines.append("__kstamp")
        // Written once, before the first attempt, because every attempt names
        // one of the two actions it defines. Tolerant of failure: a config that
        // cannot be rewritten leaves the guest tuned as it was, which is a
        // mount that answers slowly rather than no mount at all.
        lines.append(
            repairAction(
                configQ: shellQuoted(i.configPath),
                actionQ: shellQuoted(i.discoverLogPath + ".actions"),
                mergedQ: shellQuoted(i.discoverLogPath + ".actionsmerged"),
                withRepair: i.kind == .microsoft && !i.readOnly))
        lines.append("__tune_setup || true")

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
            // Before that: one more go at writing, where what stopped it was
            // the machinery rather than the drive. A slip that falls straight
            // through to the read-only attempts becomes permanent for as long
            // as the drive stays open -- it mounted, nothing looked wrong, and
            // the first save is refused by a volume nobody chose to open
            // read-only.
            //
            // Only on that evidence, and only once: a drive that genuinely
            // takes no writes must not spend another minute proving it twice.
            let slipped = """
                __slipped() {
                  grep -qiE \(shellQuoted(TransientFailure.signaturesForTheScript)) \
                    \(logQ) 2>/dev/null
                }
                """
            lines.append(slipped)
            // Every attempt again, not the first one only. A Microsoft drive
            // has two: ntfs3, which refuses a volume Windows left dirty, and
            // ntfs-3g, which mounts it. Where the refusal is real and the
            // ntfs-3g attempt is the one that slipped, retrying only the first
            // re-runs ntfs3, gets the same real refusal, and falls through to
            // read-only -- a drive silently unwritable for the rest of the
            // session, and a sentence blaming the filesystem for a slip in the
            // machinery.
            //
            // One extra pass in all: the guard is checked once before it, so a
            // drive that genuinely takes no writes does not prove it twice.
            let again = attempts(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ)
                .joined(separator: " || ")
            chain.append("{ __slipped && sleep 2 && { \(again) ; } ; }")

            // Everything below this line opens the drive read-only, which is
            // not what was asked for. The commonest reason to get here is a
            // volume Windows left dirty -- ntfs3 refuses it outright and
            // ntfs-3g answers with an I/O error -- and the remedy that used to
            // imply was not on this Mac at all: a chkdsk on a machine the drive
            // may never be plugged into again.
            //
            // ntfsfix resets the NTFS journal and clears the dirty flag, which
            // is the whole of what stops the volume being written to, and it
            // runs inside the machine that just refused the mount.
            //
            // It has to be a before_mount action. The engine's own 'shell'
            // subcommand looks like the obvious place and cannot work: vmproxy
            // takes an early return for it, initialising the network and
            // exec-ing the shell without ever running the disk setup -- so
            // nothing is decrypted and /dev/mapper/btlk0 does not exist. An
            // action does run after the decryption and before the mount.
            //
            // Nor is it guarded on evidence that the volume is dirty. That
            // guard existed and did not fire: the words are the guest kernel's,
            // they arrive in a log the script has to go and find, and reading
            // them back at the right moment is a race this does not need to
            // run. One VM boot is the whole cost, the alternative on the next
            // line is handing back a drive nobody asked to be read-only, and
            // ntfsfix on a volume that is not dirty clears a flag already
            // clear. The driver check is what keeps this off anything that is
            // not NTFS, and that is decided here rather than scraped.
            if i.kind == .microsoft {
                let repaired = attempts(
                    i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ,
                    action: repairActionName
                ).joined(separator: " || ")
                chain.append("{ \(repaired) ; }")
            }

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
        // Only where something is owed an explanation: a failure, or a mount
        // that had to give up writing. On a clean read-write mount there is
        // nothing to diagnose and the transcript stays as short as it was.
        //
        // The marker is named only on the route that can produce one. A mount
        // asked for read-only is read-only from the start and never falls back,
        // so naming it here would put the word into a script that can never
        // write it -- and the marker is read back out of the transcript as
        // evidence that a fallback happened.
        if i.readOnly {
            lines.append("[ \"$__rc\" != 0 ] && __guest_kernel")
        } else {
            lines.append(
                "{ [ \"$__rc\" != 0 ] || grep -q \"\(stageMarker)read-only\" \(logQ) "
                    + "2>/dev/null ; } && __guest_kernel")
        }
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
        // Whichever way the attempt ended, the deadline is no longer waiting on
        // it. Left running, it sits there for minutes and then kills nothing,
        // and the shell reports the signal as though the mount had failed.
        lines.append("pkill -KILL -P \"$__watchdog\" 2>/dev/null || true")
        lines.append("kill -KILL \"$__watchdog\" 2>/dev/null || true")
        lines.append("exit $__rc")
        return lines.joined(separator: "\n")
    }

    private static func attempts(
        _ i: Inputs,
        engineQ: String,
        deviceQ: String,
        logQ: String,
        action: String? = tunedActionName
    ) -> [String] {
        // A volume already chosen by the user is mounted directly: no driver
        // override, no discovery.
        if let volume = i.volume {
            return [
                mountCommand(
                    engineQ: engineQ,
                    target: shellQuoted(volume.mountIdentifier),
                    driver: nil, options: nfsOptions(i), readOnly: i.readOnly,
                    ownership: ownershipFlags(i), netHelper: netHelperFlag(i),
                    logQ: logQ, action: action)
            ]
        }

        // ntfs-3g first, not ntfs3.
        //
        // ntfs3 first, because it is the kernel driver and the only one whose
        // metadata is fast enough to feel like a disk. Deleting a folder of
        // forty thousand files is forty thousand unlinks whichever driver runs
        // them; in the kernel that is seconds, and through FUSE it is an hour.
        //
        // It is safe to serve over NFS, which an earlier version of this
        // comment denied. ntfs3 registers generic_encode_ino32_fh, so every
        // file handle carries the inode's generation, and on the way back
        // ntfs_export_get_inode puts it in ref.seq for ntfs_iget5 to compare
        // against the MFT record's own sequence number. A record reused after
        // a delete fails that comparison and the handle is refused with
        // -ESTALE. It is never resolved to the wrong file.
        //
        // What it does do is shout. Every refusal logs "Inode r=%x is not in
        // use!" at error level, so a copy that deletes as it goes fills the
        // log with hundreds of them. They are the driver working, not failing,
        // and they were read here as the cause of a failed copy once already.
        //
        // ntfs-3g stays as the fallback, for the one thing it is genuinely
        // needed for: a volume Windows left dirty, which ntfs3 refuses to
        // touch. See ntfsOptions for why it is given big_writes.
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
                    ownership: ownershipFlags(i), netHelper: netHelperFlag(i),
                    logQ: logQ, action: action)
            }
        }
        if i.kind == .linux {
            result.append(discovery(i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ))
        }
        return result
    }

    /// A deadline the script keeps on itself.
    ///
    /// `pkill -P $$` is only what this script started directly -- the engine of
    /// this attempt -- and `$$` is the script's own pid inside the subshell as
    /// well, since a subshell does not get one of its own. Nothing else on the
    /// Mac is in range of it, including the engine of a drive somebody has open.
    ///
    /// It ignores TERM, because it is a child of `$$` too and would otherwise
    /// be the first thing its own sweep took down -- leaving nothing to follow
    /// up with KILL for an engine that did not answer the first signal. Which
    /// is also why the attempt that finishes normally ends it with KILL, and
    /// ends what it is sleeping in first: a `sleep` whose parent has been
    /// killed goes on holding every pipe the script was given, and whoever is
    /// reading the far end of one waits there until the sleep is over. That was
    /// eight minutes of a spinner after a mount that had already worked.
    ///
    /// Its own output goes nowhere for the same reason: a background job that
    /// holds the script's pipes keeps them open long after the script has gone.
    private static func watchdog(seconds: Int, logQ: String) -> String {
        return """
            (
              trap '' TERM
              sleep \(seconds)
              echo "\(stageMarker)ended by the script's own deadline" >> \(logQ)
              pkill -TERM -P $$ 2>/dev/null
              sleep 10
              pkill -KILL -P $$ 2>/dev/null
            ) >/dev/null 2>&1 &
            __watchdog=$!
            """
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
    ///
    /// Narrower still than "an engine mount": one this attempt could have made.
    /// Two copies of this app -- a release and a pre-release, which is how it
    /// is tested and how some people run it -- can be opening two drives at the
    /// same moment, and a name that appeared during this window is otherwise
    /// taken as proof that *this* mount worked. It then reports success for a
    /// drive that did not open, hands back the other drive's mount point, and,
    /// where it falls back to read-only, remounts the other app's drive
    /// read-only underneath it.
    ///
    /// What narrows it is the directory an attempt of this kind can mount in.
    /// An engine running as this user mounts under their own `~/Volumes` and
    /// can mount nowhere else -- creating a directory in `/Volumes` needs a
    /// privilege they do not have -- so everything outside it belongs to
    /// somebody: the other channel, a Homebrew anylinuxfs, an NFS file server.
    ///
    /// Left empty for a privileged attempt, which mounts under `/Volumes` but
    /// is handed the invoking user's identity as well, so both are possible.
    /// Guessing wrong there would report every mount of a physical drive as a
    /// failure, and no narrowing is worth that.
    ///
    /// The share name is not used. The engine builds it from what it found
    /// rather than from what it was handed -- a group inside a container is
    /// named after the group, not the container -- so a pattern made from what
    /// this attempt knows would call some of its own mounts somebody else's.
    private static func mountHelpers(baselineQ: String, root: String) -> String {
        return """
            __engine_mounts() {
              /sbin/mount | awk -v root=\(shellQuoted(root)) \
                '/\\(nfs/ && /:\\/(mnt|run)\\// {
                   sub(/^.* on /, ""); sub(/ \\(.*$/, "")
                   if (root == "" || index($0, root) == 1) print
                 }' | sort
            }
            __rebase() { __engine_mounts > \(baselineQ); }
            __new_mounts() { __engine_mounts | grep -vxF -f \(baselineQ) || true; }
            __mounted() { [ -n "$(__new_mounts)" ]; }
            """
    }

    /// The guest kernel's account of why a filesystem refused, folded into the
    /// transcript the app diagnoses from.
    ///
    /// The engine writes two logs per run and the script only ever saw one.
    /// Its own output goes down the pipe into this transcript; the guest
    /// kernel goes to `anylinuxfs_kernel-<id>.log` beside it, and nothing read
    /// that -- `Housekeeping` knows the name only in order to delete it.
    ///
    /// Which is where the reason lives. A drive Windows left unclean is
    /// refused by ntfs3 with
    ///
    ///     ntfs3(dm-0): volume is dirty and "force" flag is not set!
    ///
    /// while the engine's own output for the same attempt says only "wrong fs
    /// type, bad option, bad superblock". So `Diagnosis` had a rule for this
    /// -- windows-hibernated, matching "dirty" and "unclean" -- that could
    /// never fire, and a drive that opened read-only because of Fast Startup
    /// was explained as one that "may need repairing", with the one setting
    /// that would fix it never named.
    ///
    /// Every log this attempt wrote, not the newest: a Microsoft drive tries
    /// ntfs3, then ntfs-3g, then read-only, and the refusal that matters is
    /// the first of the three. The newest belongs to the attempt that worked.
    ///
    /// Filtered rather than appended whole. The rules match on text and the
    /// first of them wins, so a boot log arriving entire would let "no such
    /// device" out of some unrelated probe answer a question about the
    /// filesystem -- trading an honest generic sentence for a confident wrong
    /// one. Only lines naming a filesystem driver or an unclean volume get in.
    private static func guestKernelHelpers(stampQ: String, logQ: String) -> String {
        return """
            __klogs() { echo "${\(EngineEnvironment.homeVariable):-$HOME}/Library/Logs"; }
            __kstamp() { : > \(stampQ) 2>/dev/null || true; }
            __guest_kernel() {
              [ -n "${__kread:-}" ] && return 0
              __kread=1
              __kdir=$(__klogs)
              [ -d "$__kdir" ] || return 0
              find "$__kdir" -name "anylinuxfs_kernel-*.log" -newer \(stampQ) 2>/dev/null               | sort | while read -r __k; do
                  [ -r "$__k" ] || continue
                  __said=$(grep -aiE \(shellQuoted(guestKernelPhrases)) "$__k" 2>/dev/null | tail -n 20)
                  [ -n "$__said" ] || continue
                  echo "\(guestKernelMarker) $__k" >> \(logQ)
                  echo "$__said" >> \(logQ)
                done
              return 0
            }
            # Whether the volume was refused because Windows left it unclean.
            # The words are the guest kernel's, so its log is folded in first.
            __dirty() {
              __guest_kernel
              grep -qiE \(shellQuoted(dirtySignatures)) \(logQ) 2>/dev/null
            }
            """
    }

    /// How a filesystem says it was not shut down properly.
    ///
    /// ntfs3 refuses in the kernel; ntfs-3g answers the mount with an I/O
    /// error and says nothing about why, so the kernel is the only account of
    /// either.
    public static let dirtySignatures =
        "volume is dirty|unclean file system|hiberfil|needs journal recovery"

    /// The name of the repair action generated into the engine's config.toml.
    public static let repairActionName = "lukottarepair"

    /// The same, for a mount that needs no repair. Every mount uses one of the
    /// two, because both carry the guest's tuning and a mount without it is a
    /// mount that stops answering under a long copy.
    public static let tunedActionName = "lukottatuned"

    /// How many threads the guest's NFS server runs with.
    ///
    /// The guest works this out for itself as one per CPU, and it is given two,
    /// so it serves with two. Both block in writeback to a slow drive at the
    /// same moment and nothing is answered at all -- not a write, not a
    /// getattr -- so macOS marks the mount "not responding" and Finder freezes
    /// mid-copy. It comes back when writeback drains, which is why it reads as
    /// the application breaking and repairing itself rather than as a drive
    /// that is merely busy.
    ///
    /// Eight is what rpc.nfsd's own manual suggests as a starting point, and
    /// the guest reads this variable in preference to counting CPUs. It buys
    /// the separation that matters -- being busy writing is no longer the same
    /// as being unable to answer -- for about eight kilobytes of kernel stack
    /// each, which is why it is not paid for in RAM or in cores.
    public static let nfsServerThreads = 8

    /// What the guest is allowed to leave unwritten is left alone.
    ///
    /// Bounding it looks right and is not. The reasoning was that a backlog
    /// inside the guest is what the client is waiting on, so a smaller one
    /// would be drained sooner; measured, 16 MB and 64 MB against a gigabyte
    /// took a thirteen-gigabyte copy from about 8 MB/s to about 1, and the copy
    /// then failed sooner than it had without them -- at nine minutes rather
    /// than forty.
    ///
    /// Buffering is what gives a slow device its throughput. Starving it makes
    /// every writer wait at the speed the drive takes bytes, which is the thing
    /// being worked around, and the server is no better at answering for it.
    /// Left at the kernel's own share of memory, which moves with whatever the
    /// machine is given and has no number here to be wrong.

    /// Writing that action, merged into the config rather than over it.
    ///
    /// The config also holds the user's own settings and the engine rewrites it
    /// wholesale on every run, so the old copy of this action is dropped by
    /// name and the new one appended. Truncating in place keeps whoever owns
    /// the file owning it.
    ///
    /// Backticks, not $(...): the host reads every action script for `$VAR`
    /// references and refuses to start when one names a variable it cannot
    /// resolve -- only ALFS_VM_MOUNT_POINT is defined for it. Backticks are not
    /// scanned, so the device can be looked up in the guest where the answer
    /// is, rather than guessed at from here where it is /dev/mapper/btlk0
    /// behind BitLocker and /dev/vda* without.
    ///
    /// A TOML literal string, so nothing inside needs escaping, and a quoted
    /// heredoc, so the host's own shell does not run the backticks first.
    /// Decoupling the transfer size from how much memory the guest was given.
    ///
    /// Linux nfsd picks its maximum block size from total RAM when its first
    /// thread starts, and the two are not related to each other by anything
    /// except that formula. Dropping the machine from a gigabyte to 256 MiB --
    /// which is what it actually uses -- took the size the server would grant
    /// from 128K to 32K, which is four times the round trips for the same
    /// bytes and puts the requested and granted numbers back out of step.
    ///
    /// The limit is writable while no threads are running, and this runs before
    /// any are. `/proc/fs/nfsd` is mounted by the guest's own init afterwards,
    /// so it is mounted here, written, and unmounted again: the value lives in
    /// the module rather than in the mount, and the init that follows finds
    /// everything as it expects.
    ///
    /// Failure is silent by design. A kernel that will not take it serves at
    /// whatever it chose for itself, which is the behaviour without this.
    public static var nfsBlockSize: String {
        "modprobe nfsd > /dev/null 2>&1; "
            + "mount -t nfsd nfsd /proc/fs/nfsd > /dev/null 2>&1; "
            + "echo \(transferSize) > /proc/fs/nfsd/max_block_size 2>/dev/null; "
            + "umount /proc/fs/nfsd > /dev/null 2>&1; true"
    }

    /// Clearing a dirty flag, and refusing the two cases where that is not what
    /// it would be doing.
    ///
    /// The flag by itself means a volume was not unmounted cleanly. Clearing it
    /// is what every Linux distribution does and it is what lets somebody write
    /// to their own drive. But `ntfsfix` does not replay the NTFS journal --
    /// nothing on Linux does -- it discards it, and the engine's own
    /// documentation is blunt about where that leads: "will not really fix
    /// those errors and can lead to further data corruption".
    ///
    /// That warning is about the cases where something is actually being thrown
    /// away, and those are worth separating from the case where nothing is.
    ///
    /// A hibernated volume is refused outright. Windows left a memory image
    /// describing state the disk does not have, so the on-disk filesystem is
    /// not merely unclean but deliberately stale, and writing to it loses
    /// whatever that image was going to reconcile. `hiberfil.sys` is what says
    /// so, and it is readable without mounting anything.
    ///
    /// A volume with real damage is refused too. `ntfsfix -n` is a dry run that
    /// writes nothing; where it will not answer cleanly there is more wrong
    /// than a flag, and clearing the flag would let a filesystem be written to
    /// that ntfs3 refused for a reason.
    ///
    /// Either refusal exits non-zero, which fails the action, which fails the
    /// attempt -- and the chain below opens the drive read-only, which is
    /// exactly what should happen to a volume nobody can safely write to.
    /// blkid is asked twice rather than once because an action may not name a
    /// shell variable: the engine reads every action for `$NAME` and refuses to
    /// start when it finds one it cannot resolve.
    public static let ntfsRepair =
        "ntfsls -f \"`blkid -t TYPE=ntfs -o device | head -n 1`\" 2>/dev/null "
        + "| grep -qi hiberfil && exit 1; "
        + "ntfsfix -n \"`blkid -t TYPE=ntfs -o device | head -n 1`\" > /dev/null 2>&1 || exit 1; "
        + "ntfsfix -d \"`blkid -t TYPE=ntfs -o device | head -n 1`\" || true"

    /// What both sides are asked for, and what the server is told to allow.
    public static let transferSize = 131072

    /// The environment line both actions carry.
    ///
    /// This is the only way into the guest that does not mean patching the
    /// engine: it passes a custom action's `environment` entries to the machine
    /// it starts, and nothing else of the host's except the passphrase.
    static var guestEnvironment: String {
        "environment = ['NFS_SERVER_THREAD_COUNT=\(nfsServerThreads)']"
    }

    private static func repairAction(
        configQ: String, actionQ: String, mergedQ: String, withRepair: Bool
    ) -> String {
        // Only where it can be reached. A drive opened read-only is not written
        // to at all, and ntfsfix is a write; a drive that is not NTFS has
        // nothing for it to do. Leaving the section out rather than leaving it
        // unused keeps that readable in the script itself.
        let repair =
            withRepair
            ? """

                [custom_actions.\(repairActionName)]
                description = 'Generated by Lukotta; the same, and clears the dirty flag'
                \(guestEnvironment)
                before_mount = '\(nfsBlockSize); \(ntfsRepair)'
                """ : ""
        return """
            __tune_setup() {
              cat > \(actionQ) <<'LUKOTTA_ACTION_EOF'
            [custom_actions.\(tunedActionName)]
            description = 'Generated by Lukotta; keeps the guest answering under a long copy'
            \(guestEnvironment)
            before_mount = '\(nfsBlockSize)'
            \(repair)
            LUKOTTA_ACTION_EOF
              { awk 'BEGIN { skip = 0 }
                     /^\\[/ { skip = ($0 == "[custom_actions.\(tunedActionName)]" \\
                                   || $0 == "[custom_actions.\(repairActionName)]") }
                     !skip' \(configQ) 2>/dev/null; cat \(actionQ); } > \(mergedQ) || return 1
              cat \(mergedQ) > \(configQ)
            }
            """
    }

    /// What counts as the guest kernel talking about a filesystem.
    ///
    /// Deliberately narrow, and every word here earns its place: the driver
    /// names are what prefix a refusal, and the rest is the vocabulary of a
    /// volume that was not shut down properly.
    public static let guestKernelPhrases =
        "ntfs|exfat|ext[234]|btrfs|xfs|hfsplus|vfat|dirty|unclean|hiberfil|chkdsk|journal"

    /// Marks where the kernel's account starts, so a transcript read by a
    /// person says which machine each half came from.
    public static let guestKernelMarker = "LUKOTTA_GUEST_KERNEL:"

    /// The directory this attempt's mount can appear in, or nothing when more
    /// than one is possible.
    static func mountRoot(elevated: Bool, home: String = NSHomeDirectory()) -> String {
        elevated ? "" : (home as NSString).appendingPathComponent("Volumes") + "/"
    }

    /// An awk pattern matching the share names this attempt can produce.
    ///
    /// The device alias is what the engine names the server after, and a volume
    /// group or array found inside is named after itself. A drive whose name
    /// carries anything a regular expression reads is matched by its shape
    /// alone rather than by a pattern built out of it, which is a wider net and
    /// never a wrong one.

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

    /// What a driver is mounted with, beyond read-only.
    ///
    /// ntfs-3g is FUSE, so every write crosses from the kernel out to a
    /// userspace process and back. Without big_writes that crossing happens
    /// once per 4 KiB, which is the whole of why it copies at about a megabyte
    /// a second here: not the disk, not the link, just context switches. With
    /// it, a write is up to 128 KiB and costs one crossing instead of thirty.
    /// Tuxera recommend it, and it is the first thing anyone reaches for.
    ///
    /// ntfs3 is in the kernel and has no such crossing, so it is given
    /// nothing.
    /// The engine takes one --options and refuses a second: clap answers
    /// "the argument '--options <OPTIONS>' cannot be used multiple times" and
    /// exits before touching the disk. So driver options and read-only cannot
    /// each contribute their own -o; they are joined into one.
    ///
    /// This is not hypothetical. Emitting both separately shipped for part of a
    /// day and broke every read-only ntfs-3g mount: the last resort for a drive
    /// Windows hibernated, and the whole path for anyone who chooses to open
    /// NTFS read-only. mountOptions is the only place allowed to build the flag.
    static func driverOptions(_ driver: String?) -> [String] {
        guard driver == "ntfs-3g" else { return [] }
        return ["big_writes"]
    }

    /// One -o carrying everything, or nothing at all.
    public static func mountOptions(driver: String?, readOnly: Bool) -> String {
        let opts = driverOptions(driver) + (readOnly ? ["ro"] : [])
        return opts.isEmpty ? "" : " -o \(opts.joined(separator: ","))"
    }

    /// The network helper to ask the engine for, given the macOS in front of us.
    ///
    /// vmnet is the faster of the two by a wide margin -- 2.5 times the write
    /// throughput measured on this machine, because the guest's packets reach
    /// the host through the vmnet framework with segmentation and checksums
    /// offloaded, rather than through a user-space TCP/IP stack that copies
    /// every one. It is also the one that cannot be used everywhere: opening a
    /// vmnet interface without root arrived in macOS 26, and below that the
    /// engine refuses outright --
    ///
    ///     anylinuxfs is configured to use vmnet-helper which needs sudo
    ///     unless you're on macOS Tahoe or later
    ///
    /// -- rather than falling back. Asking for it on macOS 15 would therefore
    /// break every mount on that system, so the older machines keep gvproxy.
    /// Nobody is asked anything either way; the app is supported from macOS 15.
    public static func netHelper(forMajorVersion major: Int) -> String {
        major >= 26 ? "vmnet" : "gvproxy"
    }

    /// The flag carrying that choice, for every engine command that starts a VM.
    private static func netHelperFlag(_ i: Inputs) -> String {
        " --net-helper \(i.netHelper)"
    }

    private static func mountCommand(
        engineQ: String,
        target: String,
        driver: String?,
        options: String,
        readOnly: Bool,
        ownership: String,
        netHelper: String,
        logQ: String,
        action: String? = tunedActionName
    ) -> String {
        let typeFlag = driver.map { " -t \($0)" } ?? ""
        let actionFlag = action.map { " -a \($0)" } ?? ""
        // --nfs-options must use the joined form. The flag is variadic, and the
        // separated form consumes the target that follows it.
        return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount\(ownership)"
            + "\(typeFlag)\(mountOptions(driver: driver, readOnly: readOnly))\(actionFlag) -w false"
            + "\(netHelper)"
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
    /// will accept, and says them the way the engine itself does.
    ///
    /// What --ignore-permissions actually is, read out of the engine rather
    /// than assumed -- `VmDiskContext::build_nfs_exports` in vmproxy holds two
    /// templates, and the one it picks for that flag is
    ///
    ///     {rw|ro},no_subtree_check,all_squash,anonuid=0,anongid=0,insecure
    ///
    /// Squashed to **root**, which is what bypasses the permission check in
    /// the guest. It is not what makes the files appear to belong to whoever
    /// opened the drive: that is the engine adding `uid=,gid=` to the guest's
    /// own mount, which it does on both routes and which nothing here touches.
    ///
    /// This asked for anonuid=<the user> instead, on the belief that squashing
    /// to somebody is what reports the files as theirs. Export squashing
    /// rewrites the credential a request arrives with and never the ownership
    /// a GETATTR reports, so it did the opposite of what it was reaching for:
    /// every request was performed as an unprivileged user, which is stricter
    /// than the engine's own no_root_squash default and strictly less than
    /// --ignore-permissions. A drive carrying Linux ownership -- one written
    /// through this app, which records uid 0 -- then came back with its
    /// directories owned by root, and every one of them that was not
    /// world-readable was refused. Finder draws that as a folder of zero
    /// bytes with a red badge, and the drive looks corrupt rather than shut.
    ///
    /// The other options are the engine's own defaults, kept because naming
    /// the export at all replaces them.
    static func ownershipFlags(_ i: Inputs) -> String {
        guard i.readOnly else { return " --ignore-permissions" }
        // anonuid=0, not i.uid. The engine's own template, with "ro" in front.
        let opts =
            "ro,no_subtree_check,insecure,"
            + "all_squash,anonuid=0,anongid=0"
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
        // This is NOT a hard mount, whatever the absence of "soft" here
        // suggests. Not specifying an option is not the same as choosing its
        // opposite: the engine has its own defaults and merges them over the
        // top, and on macOS they are
        //
        //     soft, intr, timeo=100, retrans=3, deadtimeout=45
        //
        // (anylinuxfs, fsutil.rs, NfsOptions::default). Every mount this
        // application has ever made has been soft, with a ten-second timeout
        // and three retries. Read back from a real mount's log, not deduced.
        //
        // Which matters, because the paragraph that used to sit here was right
        // about the danger and wrong about the facts. A soft mount does return
        // an error to a write that may already be half done, and Finder does
        // treat that as a finished file, and this application does exist to
        // move data that is often the only copy somebody has. All true, and all
        // describing what we ship rather than what we avoid.
        //
        // Upstream did not do this carelessly. A hard mount against a microVM
        // that has gone away -- a drive pulled without unmounting -- retries
        // for ever, holds IOMediaBSDClient busy, and panics the kernel once
        // watchdogd sees a registry entry stuck for sixty seconds. "soft" is
        // there to stop a panic, and removing it would bring the panic back.
        //
        // Nor can it simply be overridden from here: the merge is keyed by
        // option name, so passing "hard" adds a second key beside "soft"
        // rather than replacing it. "timeo" and "retrans" can be overridden,
        // being the same keys -- but what they should be is a question about
        // how long a slow drive is allowed to stall before its writes are
        // failed, and that wants measurement rather than a number picked here.
        //
        // An earlier audit flagged the missing timeo. It was answered from the
        // belief written above, which was mistaken. It was right.
        //
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
                  ALFS_PASSPHRASE="$__cred" \(engineQ) mount\(ownershipFlags(i))\(readOnlyFlags(i.readOnly)) -w false\(netHelperFlag(i)) --nfs-options=\(shellQuoted(nfsOptions(i))) "lvm:$__lv" >> \(logQ) 2>&1
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
          # A container of volumes is served by one machine like any other, so
          # it needs the same tuning: the thread count that keeps it answering
          # while it writes, and the bound on what it may leave unwritten. This
          # action replaces the tuned one rather than sitting beside it -- the
          # engine takes a single --action -- so the settings are repeated here
          # instead of being inherited.
          print "environment = [" q "NFS_SERVER_THREAD_COUNT=\(nfsServerThreads)" q "]"
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
                ALFS_PASSPHRASE="$__cred" \(engineQ) mount\(ownershipFlags(i))\(readOnlyFlags(i.readOnly)) -w false\(netHelperFlag(i)) --nfs-options=\(shellQuoted(nfsOptions(i))) -a \(generatedAction) "lvm:$__first" >> \(logQ) 2>&1
            """
    }
}
