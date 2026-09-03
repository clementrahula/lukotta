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
        /// What this volume's own superblock says it must be mounted with to
        /// keep what it was told to keep, or nothing where it needs nothing.
        /// See `ExtJournal.durabilityOption`.
        var durability: String? = nil

        /// What the first sector says the volume is, when anything read it.
        ///
        /// The driver ladder used to be chosen from `kind`, which is a family
        /// -- Microsoft or Linux -- and the Microsoft family's ladder is
        /// `ntfs3` then `ntfs-3g`. Neither of those mounts exFAT, so an exFAT
        /// volume whose partition type says Microsoft was handed to two NTFS
        /// drivers in turn and failed both, twice, with the machine exiting 1
        /// each time. The format is what picks a driver; the family only says
        /// which family it is in.
        var format: VolumeFormat = .unknown
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
        /// Six hundred was not the floor, and the numbers agreeing was not the
        /// whole of it. Counted again over a copy through a mount with the same
        /// rsize and wsize and the retransmit timer fixed: **none at all**.
        /// 30,470 of them in the twenty-four minutes before the change, about
        /// 1,270 a minute; zero in ten minutes of the copy after it.
        ///
        /// Which says what the message really is. A client whose retransmit
        /// interval has collapsed to the round-trip time of a healthy virtio
        /// link resends a write that is still in flight, over and over, and it
        /// is those resends that arrive malformed. The flood, the `send error`
        /// bursts and the 100060 that ends the copy are one fault with three
        /// symptoms, and the size mismatch only ever made it louder.
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
        /// `dumbtimer` is what makes any of the above true, and without it none
        /// of it was. `timeo` sets the *initial* retransmit timeout, and the
        /// dynamic estimator -- on unless `dumbtimer` says otherwise, and the
        /// mount reports `nodumbtimer` -- then replaces it with an interval it
        /// works out from observed round trips. mount_nfs(8) says so under
        /// `timeo`: "Normally, the dumbtimer option should be specified when
        /// using this option to manually tune the timeout interval."
        ///
        /// A virtio link answers in milliseconds while the guest is keeping up,
        /// so that is what the estimator learned, and what it went on using
        /// when the guest stopped keeping up. Sixty seconds was never spent.
        /// The number was in the mount table and did nothing, which is why
        /// raising it and watching a copy still fail read as the timeout being
        /// innocent -- it had not been tried yet.
        ///
        /// Read off a copy that failed at 84%: the guest logged nothing, the
        /// mount took a twenty-megabyte fsynced write a minute afterwards, and
        /// in between `Error 100060 ... on write` reached Finder, which stops
        /// the whole operation on it.
        ///
        /// `retrans` is the count those intervals are spent from, and it is the
        /// other half: at the engine's 3 a write fails after three of them.
        /// Five sixty-second tries is five minutes of silence tolerated, well
        /// past the worst stall measured here and inside the fifteen minutes
        /// `deadtimeout` allows, so a server that has genuinely gone is still
        /// let go of rather than waited on for ever.
        ///
        /// The worst is not thirty-six seconds, which is what an earlier run
        /// suggested. Through a thirteen-gigabyte Finder copy the mount went
        /// unresponsive at least ten times, of 2, 2, 10, 10, 12, 12, 23, 24 and
        /// 60 seconds -- and the copy came through every one of them, including
        /// the full minute. That single episode is the case for the margin:
        /// the engine's own three tries would not have survived it, and
        /// neither would anything sized against thirty-six.
        ///
        /// "At least": those counts come from polling `nfsstat -m` for the
        /// unresponsive flag every two seconds, and that flag was later shown
        /// to miss spells the clock catches -- a plain stat of 7.7 seconds went
        /// by with the flag never seen raised. Every episode count in this file
        /// is a floor. The durations are real; the number of them is not.
        ///
        /// Both are overridable where `hard` is not: the engine merges by
        /// option name, so `timeo`, `retrans` and `dumbtimer` replace or join
        /// its defaults, while `hard` would land beside `soft` rather than
        /// instead of it. Keeping `soft` is deliberate -- see nfsOptions(_:)
        /// for the panic it avoids.
        ///
        /// Twice now, and the second time on a configuration checked in the
        /// guest's own transcript rather than inferred from the app binary:
        /// 13,631,488,000 of 13,631,488,000 bytes, ditto exit 0, in 3227
        /// seconds. The copy completing is not in doubt any more.
        ///
        /// What is still wrong is what it looks like while it runs. Timing a
        /// request once a second through that same successful copy, 911
        /// samples: p50 0.028s, p90 0.031s, p99 4.66s, worst 8.95s, with nine
        /// past the five seconds macOS waits before saying the server has
        /// stopped answering. Nine tenths of the run is faster than a
        /// thirty-first of a second and the rest is a cliff.
        ///
        /// Measured either side of the change, same thirteen gigabytes, same
        /// drive at 92% full, same guest:
        ///
        ///   nodumbtimer, retrans=3   stopped at 11,534,356,480 bytes of
        ///                            13,631,488,000 -- 84%, four files left at
        ///                            zero length, error 100060 on screen
        ///   dumbtimer, retrans=5     13,631,488,000 of 13,631,488,000, in 2448
        ///                            seconds, and every one of the twenty-six
        ///                            files read back through the mount with a
        ///                            matching SHA-256
        ///
        /// The read-back is the half that had never been done. Two earlier runs
        /// were called complete on a byte total and a file count, neither of
        /// which can tell thirteen gigabytes of the right bytes from thirteen
        /// gigabytes of the wrong ones.
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
        /// The transfer size stays at 128K because making it smaller was tried
        /// and was worse. Same drive, one 500 MB file, the flush window after
        /// the close included:
        ///
        ///     wsize=131072   written in 64s   p99 4.10s  worst 4.21s   none over 5s
        ///     wsize=32768    written in 62s   p99 6.41s  worst 10.03s  two over 5s
        ///
        /// The reasoning for trying it was that a write RPC cannot be answered
        /// until the guest has taken all of it, so a quarter of the payload
        /// should be a quarter of the wait. It is not: four times the round
        /// trips for the same bytes means four times as many things queued
        /// behind whatever is slow, and the tail more than doubles.
        ///
        /// With the thread count also tested and also worse, what ships is the
        /// best of the three configurations measured, not a guess.
        ///
        /// Checked in force rather than assumed, on a live mount of a real
        /// drive: `nfsstat -m` reports every one of these among the current
        /// parameters -- rsize and wsize at 131072, readahead 128, dumbtimer,
        /// timeo 600, retrans 5, deadtimeout 900 -- with `noowners` among the
        /// general flags, where it belongs, and `soft` added by the engine as
        /// expected. The merge takes all of them.
        ///
        /// Worth doing because the merge is the one thing here nobody controls,
        /// and a value it quietly discards looks exactly like a value that did
        /// not help.
        var nfsOptions =
            "rsize=\(MountScript.transferSize),wsize=\(MountScript.writeSize),"
            + "readahead=128,dumbtimer,timeo=600,retrans=5,deadtimeout=900,"
            + "mutejukebox,noowners"

        /// Add `sync` to the client's own options, for a volume this app cannot
        /// see inside.
        ///
        /// The durability option that saves ext4 and XFS is chosen by reading
        /// the filesystem's superblock, and a LUKS container hides exactly
        /// that. Measured: ext4 inside LUKS, machine killed, 8 of 8 fsynced
        /// files present and all 8 wrong, with no option applied because none
        /// could be chosen.
        ///
        /// A synchronous client fixes it whatever is inside -- 8 of 8 kept,
        /// 30 of 30 in-flight files complete -- because the writes go stable
        /// rather than going unstable and being committed afterwards, and the
        /// commit afterwards is the part that does not hold.
        ///
        /// It is not used everywhere, because it is not free: 2000 small files
        /// cost the same either way, and a corpus with a gigabyte in it goes
        /// from 12 seconds to 17. Where the superblock can be read, the cheaper
        /// per-filesystem option is used instead and this stays off.
        public mutating func askForStableWrites() {
            guard !nfsOptions.contains("sync") else { return }
            nfsOptions += ",sync"
        }

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
            luksMinRamMiB: Int? = nil, durability: String? = nil,
            format: VolumeFormat = .unknown
        ) {
            self.format = format
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
            self.durability = durability
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
        /// Every one of those results is confounded, and the paragraph above
        /// is kept only to say so. All of them were measured through a mount
        /// carrying `nodumbtimer`, where the client gave up after three
        /// millisecond-scale intervals whatever `timeo` said -- so each run
        /// ended for a reason that had nothing to do with how much memory the
        /// guest had, and "256 failed" is very likely the timeout failing at
        /// 256 rather than the memory. See Inputs.nfsOptions.
        ///
        /// Which matters most where it is most expensive. The conflict below
        /// is drawn from those same numbers, and the cheap experiment that
        /// settles it -- re-asking 256 with the timeout fixed -- has to be run
        /// before anything is built on the conclusion.
        ///
        /// The figure is a ceiling rather than an allocation, libkrun backing
        /// guest memory lazily, but it is not free for being lazy: the scratch
        /// directory a container's volumes are served from is sized from it,
        /// so an inflated number reports free space that does not exist.
        ///
        /// Measured with one drive open and a copy running: 502 MB resident
        /// for the machine and its two helpers, against 170 MB when the guest
        /// was given 256 and about 1180 MB when it was given a gigabyte.
        ///
        /// Which was then multiplied by twelve, called 5.9 GB, and used to
        /// conclude that a dozen drives cannot fit on an eight-gigabyte Mac.
        /// That conclusion is wrong, and it was wrong by an order of magnitude.
        /// Eleven volumes were opened one at a time on this Mac and each was
        /// asked whether it answered:
        ///
        ///     2 open    143 MB      7 open    416 MB
        ///     3 open    166 MB      8 open    313 MB
        ///     4 open    190 MB      9 open    409 MB
        ///     5 open    352 MB     10 open    509 MB
        ///     6 open    265 MB     11 open    587 MB
        ///
        /// Eleven at once for 587 MB, with a home directory still listing in
        /// 21 ms throughout. About forty megabytes a volume, not five hundred.
        ///
        /// Run again with each volume written to and read back, which is what
        /// the claim actually says -- open for reading and writing, not merely
        /// mounted:
        ///
        ///      2 open, 2 writable    185 MB     8 open,  8 writable    728 MB
        ///      3 open, 3 writable    337 MB     9 open,  9 writable    878 MB
        ///      4 open, 4 writable    493 MB    10 open, 10 writable   1014 MB
        ///      5 open, 5 writable    646 MB    11 open, 11 writable   1124 MB
        ///      6 open, 6 writable    802 MB    12 open, 12 writable   1235 MB
        ///      7 open, 7 writable    789 MB
        ///
        /// Twelve open, twelve taking a write and giving the bytes back, for
        /// 1235 MB. A home directory listed in 18 to 19 ms at every step from
        /// two volumes to twelve -- the figure never moved, so nothing degraded
        /// as they accumulated.
        ///
        /// And on past the dozen, since the fixture holds thirteen -- one more
        /// than the box claims:
        ///
        ///     13 open, 13 writable   1038 MB, then 490 MB a minute later
        ///
        /// The footprint fell by half while the volumes stayed open, which is
        /// the plainest demonstration that most of it was never per-volume
        /// cost. It is the guests' page cache, and macOS takes it back when
        /// something else wants it.
        ///
        /// About 150 MB a volume once written to, against 40 idle: the write is
        /// what fills the guest's cache. Both are far from the 500 that a
        /// single volume under a thirteen-gigabyte copy suggested.
        ///
        /// The error was measuring one volume *under a thirteen-gigabyte copy*
        /// and calling that what a volume costs. Almost all of that 502 MB is
        /// page cache belonging to the copy, and it is not per-volume: an open
        /// drive nobody is writing to holds a fraction of it. Somebody with a
        /// dozen drives open is not copying to a dozen drives at once.
        ///
        /// So the ceiling is not memory, and the engine does not need patching
        /// to serve several drives from one machine. That was days of work
        /// argued for by a number nobody had taken.
        ///
        /// There is no conflict between a copy that does not stall and a dozen
        /// drives open together. Eleven were open at once for 587 MB while this
        /// Mac stayed responsive, which settles it without changing this number
        /// at all.
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

        // One more look, once everything has settled.
        //
        // Every per-attempt check fired too early. ntfs-3g on a dirty volume
        // comes up read-write and demotes itself afterwards, so at the moment
        // the attempt returns the mount is genuinely writable and every test
        // -- the mount table, access(2), even creating a file -- says so
        // truthfully. The demotion arrives later, the chain has already
        // stopped at that rung, and the repair below it never runs. That is
        // how a drive was handed back read-only with no repair attempted, four
        // engine attempts deep and not one of them the repair.
        //
        // So the question is asked again at the end, when the answer has
        // stopped changing: if writable was asked for and what is mounted is
        // not writable, drop it and go on down the ladder from the repair.
        if !i.readOnly, i.kind == .microsoft {
            let repairedAgain = attempts(
                i, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ,
                action: repairActionName
            ).joined(separator: " || ")
            var readOnlyAgain = i
            readOnlyAgain.readOnly = true
            let roAgain = attempts(readOnlyAgain, engineQ: engineQ, deviceQ: deviceQ, logQ: logQ)
                .map { "{ \($0) && echo \"\(stageMarker)read-only\" >> \(logQ) ; }" }
                .joined(separator: " || ")
            lines.append(
                """
                sleep 3
                if __mounted && ! __mounted_writable; then
                  __drop_new
                  { \(repairedAgain) ; } || \(roAgain)
                fi
                """)
        }

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
                    logQ: logQ, durability: i.durability, action: action)
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
        // exFAT is a Microsoft filesystem and neither NTFS driver will touch
        // it, so it goes down the same route as everything else: nil, and the
        // engine mounts what it found. Only NTFS -- and BitLocker, which is
        // NTFS once it is unlocked -- wants the pair.
        let wantsNTFS = i.kind == .microsoft && i.format != .exfat
        let drivers: [String?] = wantsNTFS ? ["ntfs3", "ntfs-3g"] : [nil]
        // The engine resolves whatever target it is handed by prefixing /dev/,
        // so an alias elsewhere never resolves and produced a
        // "disk /dev//var/folders/… not found" line ahead of every mount.
        let alias = i.aliasPath.flatMap { $0.hasPrefix("/dev/") ? $0 : nil }
        let targets = [alias.map(shellQuoted), deviceQ].compactMap { $0 }

        var result = targets.flatMap { target in
            drivers.map { driver in
                // The writable ntfs3 attempt, and nothing else, goes through
                // the probe. Not the ntfs-3g rung, which must still get its
                // turn when the probe has refused ntfs3; not the read-only
                // retry, which cannot do the damage; and not the repair rung,
                // which is asked for on purpose and carries its own action.
                // The writable ntfs3 attempt, and nothing else, goes through
                // the probe. Not the ntfs-3g rung, which must still get its
                // turn when the probe has refused ntfs3; not the read-only
                // retry, which cannot do the damage; not the repair rung,
                // which is asked for on purpose.
                //
                // This was switched off for a while on a wrong diagnosis. The
                // owner's BitLocker drive came up read-only, the probe was the
                // newest change, and it was blamed. It was not the cause: the
                // volume was dirty with $MFTMirr behind $MFT, and turning the
                // probe off changed nothing -- though that took a while to see,
                // because the daemon had not been replaced either and three
                // rebuilds in a row were served by code no longer on disk.
                //
                // With the drive repaired the question could finally be asked
                // properly, and the answer is that the probe is harmless here:
                // the drive opens through ntfs3, writable, a write succeeds,
                // and it survives an eject and reopen with the probe running
                // each time. So it is back on, where it stops ntfs3 rewriting
                // two megabytes of a damaged volume -- the journal's RSTR
                // signature among it -- during a mount it then refuses.
                let chosen =
                    (driver == "ntfs3" && !i.readOnly && action == tunedActionName)
                    ? ntfs3ProbeActionName : action
                return mountCommand(
                    engineQ: engineQ, target: target, driver: driver,
                    options: nfsOptions(i), readOnly: i.readOnly,
                    ownership: ownershipFlags(i), netHelper: netHelperFlag(i),
                    logQ: logQ, durability: i.durability, action: chosen)
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
            __drop_new() {
              __new_mounts | while IFS= read -r __m; do
                [ -n "$__m" ] && /sbin/umount -f "$__m" > /dev/null 2>&1
              done
              sleep 2
              true
            }
            __mounted_writable() {
              __mounted || return 1
              __m="$(__new_mounts | head -n 1)"
              [ -n "$__m" ] || return 1
              sleep 1
              if ! ( : > "$__m/.lukotta-write-probe" ) 2>/dev/null; then
                __drop_new; return 1
              fi
              rm -f "$__m/.lukotta-write-probe" > /dev/null 2>&1
              case "$(/sbin/mount | grep -F " on $__m (")" in
                *read-only*) __drop_new; return 1 ;;
              esac
              return 0
            }
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

    /// The action used for the writable ntfs3 attempt, and only that one.
    ///
    /// It carries a read-only probe that ntfs3 must pass before ntfs3 is
    /// allowed to touch the volume writably. Separate from the tuned action
    /// because the ntfs-3g rung and the repair rung must not inherit it: if the
    /// probe fails, the whole point is that those two still get their turn.
    public static let ntfs3ProbeActionName = "lukottantfs3"

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
    /// Eight is not enough, and the reason took a dead mount to find.
    ///
    /// The note that stood here said more threads was not the lever, reasoning
    /// from the client: `nfsiod_thread_max` is 16 and `nfsiod_thread_count`
    /// was 1, so one thread issues the writes and eight servers are never all
    /// taken. That is true of one mount and says nothing about two.
    ///
    /// With a copy running on one mount of this server and a second, idle
    /// mount of the same server beside it, the idle one was answered so rarely
    /// that it was declared dead:
    ///
    ///     kernel (nfs) nfs server disk4s1.local:/mnt/BACKUP2_TS: dead
    ///     diskarbitrationd removed disk, id = /Volumes/BACKUP2_TS
    ///
    /// `deadtimeout` is fifteen minutes, and it is only reached by fifteen
    /// unbroken minutes of not being answered. Nothing was wrong with that
    /// mount. Every thread was inside writeback for the busy one, and a
    /// statfs on the quiet one waited behind them until macOS gave up, took
    /// the volume away, and the engine -- with nothing left to serve -- shut
    /// itself down and ended the copy that had starved it.
    ///
    /// It is not the dozen-volumes problem, which is what the first version of
    /// this note called it. Twelve drives is twelve machines with eight threads
    /// each, and one drive's copy cannot reach another drive's pool. That much
    /// was overstated and is withdrawn.
    ///
    /// What it is is narrower and still real: one machine's threads are shared
    /// by everything talking to that machine, and a drive has more than one
    /// thing talking to it. Finder copies while Spotlight indexes the same
    /// volume -- mds is in the log beside the eviction -- and anything else
    /// that stats it joins the same queue. A copy heavy enough to hold every
    /// thread starves the rest of its own drive's traffic, and fifteen minutes
    /// of that is a volume macOS takes away.
    ///
    /// So eight is chosen against one consumer when a drive routinely has
    /// several.
    ///
    /// It stays at eight because raising it was tested and was worse. Same
    /// drive, one 500 MB file, the flush window after the close included, and
    /// the guest's own log confirming the count each time:
    ///
    ///      8 threads   written in 64s   p99 4.10s  worst 4.21s  none over 5s
    ///     32 threads   written in 91s   p99 3.07s  worst 6.64s  one over 5s
    ///
    /// Slower to write and a longer tail, over the line once. So a thread
    /// emptying the buffer is not a thread the others are waiting for -- more
    /// of them simply put more writers on a drive that manages twelve
    /// megabytes a second, and the queue grows rather than drains.
    ///
    /// Which leaves the write path itself rather than who is servicing it, and
    /// costs ninety seconds to have found out instead of an afternoon.
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

    /// Start writing dirty pages out early, without ever blocking the writer.
    ///
    /// The mount is marked "not responding" when a request goes unanswered for
    /// longer than `nfs.client.initialdowndelay` -- **five seconds**, read from
    /// the running kernel with an empty /etc/nfs.conf, not the twelve nfs.conf(5)
    /// still claims. So that is the budget: a single write RPC that takes more
    /// than five seconds is enough, and macOS puts that on screen
    /// -- which is a copy that looks broken to somebody watching it, whether or
    /// not it later finishes. Measured on a thirteen-gigabyte copy into a USB
    /// drive at 92% full: at least five episodes in nine minutes, of 6, 14, 16,
    /// 18 and 35 seconds. The copy survived all five. Nobody watching it would
    /// have believed that.
    ///
    /// A floor rather than a count. Those come from polling the unresponsive
    /// flag every two seconds, and the flag was later shown to miss spells that
    /// timing a request finds -- see Inputs.nfsOptions.
    ///
    /// An nfsd thread goes quiet because it is inside balance_dirty_pages, not
    /// because it is busy: once dirty pages reach the hard limit the writer is
    /// held there until writeback catches up, and on a slow nearly-full drive
    /// that is tens of seconds.
    ///
    /// That is the theory this was built on, and the measurement does not fit
    /// it. Sampled every second through an eighty-nine-second stall, with the
    /// tuning already in force:
    ///
    ///     guest process CPU     0.0%, RSS unchanged at 481 MB
    ///     physical drive        0.00 MB/s, for the whole stall
    ///     TCP to the guest      recvq=0 sendq=0 ESTABLISHED
    ///     TCP retransmits       0 packets, 0 retransmit timeouts
    ///
    /// Writeback catching up would show as disk throughput and it shows none.
    /// A guest working through something would show as CPU and it shows none.
    /// A lost request would show as a TCP retransmit and there are none, on a
    /// connection that stays established throughout. Nothing anywhere is
    /// moving, and then after about a minute it resumes on its own.
    ///
    /// The drive is not the ceiling either, which was the next guess: across
    /// 178 samples of a running copy it was completely idle in 119 of them,
    /// with a p90 of 12 MB/s and a peak of 18. It is not being kept busy.
    ///
    /// Stall lengths of 59, 71 and 89 seconds against a `timeo` of 60 looked
    /// like multiples of the client's retransmit timer, and that guess is
    /// withdrawn: later runs stalled for 290 and 659 seconds and recovered
    /// without an error, which no multiple of five sixty-second tries allows.
    ///
    /// They are two different clocks, and conflating them is what made the
    /// arithmetic seem broken:
    ///
    ///   "not responding"   a mount-level flag, raised when the oldest
    ///                      outstanding request has gone unanswered for
    ///                      `nfs.client.initialdowndelay` -- five seconds --
    ///                      and lowered when one is answered again. It is what
    ///                      macOS puts on screen.
    ///   ETIMEDOUT          per call, after `retrans` retransmit intervals with
    ///                      no reply. It is what ends a copy.
    ///
    /// So a mount can be flagged unresponsive for eleven minutes while every
    /// individual call still completes inside its own budget, which is exactly
    /// what a 659-second spell that recovered looks like. Widening `retrans`
    /// buys the copy resilience and does nothing for what is shown on screen;
    /// only shorter round trips do that.
    ///
    /// And the flag is a verdict, not the measurement. A run that never raises
    /// it can still be a second away from raising it all the way through, and
    /// one was: timing a plain `stat` on the mount once a second through a copy
    /// that recorded no unresponsive spells at all --
    ///
    ///     p50 0.028s, p90 0.70s, p99 5.31s, worst 8.95s, against a
    ///     threshold of 5 -- over 507 samples, 36 past two seconds and six
    ///     past five
    ///
    /// -- which is not a healthy mount that occasionally hesitates. Six
    /// requests went unanswered for longer than macOS waits, during a copy
    /// whose unresponsive flag was polled every two seconds and never once seen
    /// raised.
    ///
    /// The shape is worth as much as the numbers. Half of all requests come
    /// back in twenty-eight milliseconds and nine in ten inside a second: the
    /// mount is not slow. It is quick almost always and occasionally stops
    /// dead, and it is the tail that reaches somebody, not the median.
    ///
    /// The slow moments are not scattered evenly through the copy either. Lined
    /// up against when each file was actually written -- the destination's
    /// inode change times, since ditto carries the source's mtime across --
    /// they fall in clusters in the thirty to fifty seconds *after* a file
    /// closes, not at the moment it closes:
    ///
    ///     file finished 15:16:22   slow at :32, :46, :54
    ///     file finished 15:17:38   slow at 15:18:06, 15:18:33
    ///     file finished 15:19:20   slow at 15:19:53, 15:20:00, 15:20:14
    ///
    /// Which is the shape of a flush rather than of a slow device. NFS commits
    /// a file when it is closed, the guest then has half a gigabyte of buffered
    /// writes to push to a drive that manages about twelve megabytes a second,
    /// and anything asking a question during that window waits behind it.
    ///
    /// And the control that settles what it is. The same measurement, through
    /// the same guest, the same protocol and the same mount options, with only
    /// the device underneath changed -- a 400 MB file into an ext4 image on the
    /// internal disk instead of 500 MB into the USB stick:
    ///
    ///     USB stick      written in 64s   p99 4.10s   worst 4.21s
    ///     internal disk  written in  2s   p99 0.033s  worst 0.033s
    ///
    /// A hundred and twenty times faster to write and no tail whatsoever. The
    /// latency is the device, not the path to it: nothing in NFS, the guest,
    /// the transfer size or the thread pool produces this on hardware that can
    /// absorb the writes.
    ///
    /// Which is why every knob tried has been neutral or worse. A drive taking
    /// twelve megabytes a second cannot swallow half a gigabyte quickly, and
    /// whatever asks it a question meanwhile waits. That is arithmetic, and no
    /// setting here repeals it.
    ///
    /// Two things it is not, both checked rather than assumed.
    ///
    /// Not how full the drive is. The same 500 MB measurement at 12,437 MB free
    /// and again at 20,203 MB free: worst 4.21s and 4.44s, five samples past
    /// two seconds each time, none past five either time. Six gigabytes of
    /// headroom changed nothing.
    ///
    /// And not every writer. Two Finder cycles moving 2.4 GB of large files
    /// onto the same drive, sampled through the large-file phase, gave a worst
    /// of 0.030s -- no tail at all. Finder moved it at about 2.9 MB/s where dd
    /// with conv=fsync moves it at 6.5, and a writer slow enough for writeback
    /// to keep up never builds the buffer that has to be emptied. The tail
    /// belongs to writing faster than the drive can absorb, not to writing.
    ///
    /// So the remaining question is not how to make the wait shorter. It is
    /// whether macOS has to call a wait of that length a server that has
    /// stopped answering. `mutejukebox` is the answer to that, and it is the
    /// only per-mount option that speaks of the dialog at all:
    ///
    ///     "Use of this option will prevent the file system from being
    ///      included in the list of unresponsive file systems that would be
    ///      included in a dialog presented to the user."
    ///
    /// mount_nfs(8) describes it under jukebox errors, which is where it came
    /// from -- a hierarchical store expected to be slow. This drive is the
    /// same case with a different cause: a copy going perfectly well that
    /// takes four seconds to answer because half a gigabyte is being pushed to
    /// something managing twelve megabytes a second. Nothing is wrong, and a
    /// dialog saying the server has stopped answering is wrong about it.
    ///
    /// It is asked for and it lands -- `nfsstat -m` reports `mutejukebox`
    /// where the same mount without it says `nomutejukebox` -- and it changes
    /// nothing about how anything is written, only whether the volume is
    /// listed as unresponsive.
    ///
    /// What is not established from here is whether that exclusion covers
    /// every cause or only the jukebox errors it is documented under. It
    /// shows on a screen during a slow copy, and in no counter this can read.
    ///
    /// Measured where it counts: a thirteen-gigabyte copy through Finder onto
    /// the drive this was reported on, which is the shape of the original
    /// complaint rather than a reproduction of it. Timing a request once a
    /// second, 687 samples in:
    ///
    ///     p50 0.028s, p99 1.88s, worst 5.90s, three requests past five
    ///     seconds -- and nothing said about any of them:
    ///     copy-engine errors 0, items skipped 0, volumes removed 0,
    ///     not responding 0
    ///
    /// Three waits over the line macOS draws, and no dialog behind any of them.
    /// The same drive before this option was added had the mount marked
    /// unresponsive ten times in one copy.
    ///
    /// The wait is untouched, which was never the aim. What changed is that it
    /// no longer reaches anybody.
    ///
    /// A smaller measurement said the same thing first: a 500 MB file, worst
    /// wait 5.85s, one request past five seconds, `Status flags: 0x0` in all
    /// 105 samples.
    ///
    /// Weaker evidence than it reads, because that flag was shown earlier the
    /// same day to miss spells the clock catches: silence from an instrument
    /// known to under-report is not proof. What it does establish is that the
    /// latency is untouched, which was expected -- the option changes what is
    /// reported, not what is waited for.
    ///
    /// Taken anyway. The app knows the state of its own drives and says so in
    /// its own window; a second opinion from macOS about a volume it is
    /// managing, delivered as an alert in the middle of a copy that is fine,
    /// is noise whichever cause raised it.
    ///
    /// The control says the same thing. Reading those thirteen gigabytes back
    /// off the same drive, through the same mount, minutes later:
    ///
    ///     reading   p50 0.028s  p90 0.030s  p99 0.043s  worst 0.043s
    ///     writing   p50 0.028s  p90 0.031s  p99 4.66s   worst 8.95s
    ///
    /// Nothing over two seconds in the whole read; forty-five over two and nine
    /// over five in the write. Same drive, same guest, same link, two hundred
    /// times the worst case. Sampled a second time during a later read-back,
    /// separately: worst 0.031s over forty samples, again nothing past two
    /// seconds. The read side is not merely better, it is flat. So it is not a slow device, not the virtio link,
    /// and not the microVM being starved of anything: it is the write path,
    /// and specifically what happens to everything else while committed data
    /// is being pushed out.
    ///
    /// So the flag is not merely a coarse view of the latency, it is an
    /// unreliable one: `nfsstat -m` was answering from client state that did
    /// not show a spell the timing caught plainly. "No unresponsive episodes"
    /// is what a stall looks like through the wrong instrument, and it was
    /// nearly written down as the first clean run of the day.
    ///
    /// Which is a different knob from the one tried before. Bounding
    /// `vm.dirty_bytes` -- the hard limit -- at 16 MB and 64 MB took the same
    /// copy from about 8 MB/s to about 1 and made it fail sooner, because
    /// buffering is what gives a slow device its throughput. That result stands
    /// and the limit is left alone.
    ///
    /// `dirty_background_bytes` is the other end: the point where the flusher
    /// starts working, not the point where the writer is stopped. Setting it
    /// low means writeback runs continuously from early on, so the hard limit
    /// is approached slowly if at all, and the writer keeps its buffer. The
    /// expiry and wakeup intervals go with it so pages are not held for the
    /// default thirty seconds before anybody looks at them.
    ///
    /// Written through /proc rather than sysctl(8): the guest is trimmed, and
    /// what is not in it cannot be called. Failure is silent for the same
    /// reason as the block size -- a kernel that will not take it behaves as it
    /// did without this.
    /// Not applied. Kept as the record of a change that made things worse.
    ///
    /// Measured against the run it was meant to improve, same thirteen
    /// gigabytes, same drive, same 512 MiB, same client:
    ///
    ///     without it   13,631,488,000 of 13,631,488,000, ditto exit 0,
    ///                  seven unresponsive episodes and every one recovered
    ///     with it      hung at about 3.2 GB. Episodes of 59, 71 and 290
    ///                  seconds, then one that never ended: quiet from
    ///                  13:34:51 until the kernel declared the mount dead at
    ///                  13:55:10 and macOS took the volume away. Nothing was
    ///                  delivered.
    ///
    /// Through the twenty minutes of silence the drive was idle in 889 of 891
    /// samples and the guest used no CPU worth the name. It did not slow down;
    /// it stopped.
    ///
    /// Why is not established. Starting writeback early should be the gentler
    /// end of the same mechanism -- where the flusher begins rather than where
    /// the writer is stopped -- and the reasoning for it still reads well.
    /// It is wrong anyway, which is the only part that counts.
    ///
    /// Left here rather than deleted so the next person to reason their way to
    /// it finds the measurement first. Both ends of vm.dirty_* have now been
    /// tried on this drive: the hard limit cost seven eighths of the
    /// throughput, and the background threshold cost the whole copy.
    static var writebackLatencyNotApplied: String {
        "echo 16777216 > /proc/sys/vm/dirty_background_bytes 2>/dev/null; "
            + "echo 200 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null; "
            + "echo 100 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null; true"
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
    /// Why the guard reads the dry run's words instead of its exit status.
    ///
    /// `ntfsfix -n` is the no-action pass, and the guard used to be
    /// `ntfsfix -n ... || exit 1` -- refuse whatever the dry run reports a
    /// failure for. On the owner's drive, whose $MFTMirr had fallen behind
    /// $MFT, that dry run says:
    ///
    ///     Mounting volume... $MFTMirr does not match $MFT (record 3).
    ///     FAILED
    ///     Attempting to correct errors...
    ///     Comparing $MFTMirr to $MFT... FAILED
    ///     Correcting differences in $MFTMirr record 3...OK
    ///     Processing of $MFT and $MFTMirr completed successfully.
    ///     Setting required flags on partition... OK
    ///     Going to empty the journal (LogFile)... OK
    ///     $MFTMirr does not match $MFT (record 3).
    ///     Remount failed: I/O error
    ///
    /// It corrects everything, in memory, and then fails to remount because a
    /// dry run writes nothing and the disk is still as it was. So the failure
    /// at the end is the dry run being a dry run, and the old guard refused
    /// exactly the volumes ntfsfix knows how to repair -- which is the whole
    /// set the repair exists for. A drive was handed back read-only on the
    /// strength of it.
    ///
    /// What the dry run does say, when it can help, is that it processed $MFT
    /// and $MFTMirr successfully. That is the sentence to gate on: a volume it
    /// cannot process never prints it, and a volume it can does. The
    /// hibernation refusal above is unchanged, and so is the rule that this
    /// only ever runs on NTFS and only when writable was asked for.
    ///
    /// Double quotes around the pattern, not single. The whole action is a
    /// single-quoted TOML value, so a single quote inside it ends the string:
    /// the first attempt at this guard wrote `grep -q 'completed successfully'`
    /// and the engine answered with a TOML parse error at that line and mounted
    /// nothing at all.
    public static let ntfsRepair =
        "ntfsls -f \"`blkid -t TYPE=ntfs -o device | head -n 1`\" 2>/dev/null "
        + "| grep -qi hiberfil && exit 1; "
        + "ntfsfix -n \"`blkid -t TYPE=ntfs -o device | head -n 1`\" 2>&1 "
        + "| grep -q \"completed successfully\" || exit 1; "
        + "ntfsfix -d \"`blkid -t TYPE=ntfs -o device | head -n 1`\" || true"

    /// Let ntfs3 look before it writes.
    ///
    /// ntfs3 modifies a volume during a mount it then refuses. Measured on
    /// three MFT-damage images from the ntfsprogs-plus corpus, identically on
    /// all three: the writable attempt is declined and the image comes back
    /// changed, before anything of ours has decided to attempt a repair. On a
    /// ten-megabyte image it rewrote 2,080,371 bytes across five regions, and
    /// the first of them was the `RSTR` restart signature of the NTFS journal,
    /// overwritten with 0xFF.
    ///
    /// That is the journal a Windows chkdsk would have used. So a disk somebody
    /// brought here *because* it was damaged goes home less recoverable than it
    /// arrived, and without having been opened. It is the exact thing the
    /// engine's own notes warn about, arriving from the driver rather than from
    /// ntfsfix, which is where it was first looked for.
    ///
    /// Read-only ntfs3 does not do it. Same three images: refused, and the
    /// image byte-identical afterwards. A healthy volume mounts read-only,
    /// reads, and is left byte-identical too. So read-only is both a safe probe
    /// and an accurate one, and this runs it first.
    ///
    /// It costs nothing a person can see. `before_mount` runs inside the
    /// machine that is already booting for this mount, so there is no second
    /// virtual machine and no second wait -- a mount and an unmount inside the
    /// guest, on a volume that is about to be mounted anyway.
    ///
    /// WHAT IT COSTS, MEASURED TWICE BECAUSE THE FIRST ANSWER WAS THE TOOLING
    ///
    /// Nothing. On the corpus: the three MFT-damage images are refused and come
    /// back byte-identical, where before each was written to and then refused.
    /// `1k_cluster_fsck_error` and `block_overflow_hole_file`, which only
    /// writable ntfs3 will open, still open through writable ntfs3. A volume
    /// formatted by Windows still takes the fast path.
    ///
    /// That is the second answer. The first said the probe cost access to those
    /// two, and a decision was written down and committed on the strength of
    /// it: that refusing them was the right trade because a disk we cannot open
    /// should go back as it arrived. The reasoning was sound and the number
    /// underneath it was rubbish.
    ///
    /// The harness that produced it removes its custom actions from config.toml
    /// between runs, with a regex ending `[^\[]*` -- which stops at the first
    /// "[" it meets, and the line below the header is
    ///
    ///     environment = ['NFS_SERVER_THREAD_COUNT=8']
    ///
    /// So every run deleted a header and orphaned its body. The file degraded
    /// one stray line at a time until the engine would not parse it at all, and
    /// in between it produced mounts that failed for a reason that had nothing
    /// to do with the volume. Two corpus runs and one recorded trade-off came
    /// out of that window.
    ///
    /// The tell was a healthy Windows volume being refused, which no honest
    /// account of this change could explain.
    ///
    /// No `$NAME` anywhere: the engine reads every action for a shell variable
    /// and refuses to start when it finds one. Hence blkid asked three times
    /// rather than once, as in ntfsRepair above.
    public static let ntfs3Probe =
        "blkid -t TYPE=ntfs -o device | head -n 1 | grep -q . || exit 0; "
        + "mkdir -p /tmp/lukotta-probe; "
        + "mount -t ntfs3 -o ro \"`blkid -t TYPE=ntfs -o device | head -n 1`\" "
        + "/tmp/lukotta-probe 2>/dev/null || exit 1; "
        + "umount /tmp/lukotta-probe 2>/dev/null || true"

    /// How much of a write goes in one request.
    ///
    /// Smaller than the read size, and deliberately. Listing the folder being
    /// copied into is a READDIR that shares one TCP connection with the write
    /// stream, and a 128 KiB write ahead of it in that socket is 128 KiB the
    /// listing waits for. Measured on the owner's drive, same copy, same
    /// sampling, the busy folder listed every four seconds:
    ///
    ///     wsize=131072   median 7.11s   worst 90.05s   ~5.0 MB/s
    ///     wsize=32768    median 8.27s   worst 11.48s    7.5 MB/s
    ///     wsize=32768    median 8.36s   worst 16.56s    7.2 MB/s   (repeat)
    ///
    /// The median is a second worse and the tail is five to eight times
    /// better, and the copy is faster besides. Nobody notices the difference
    /// between seven seconds and eight; a folder that stops answering for a
    /// minute and a half is the thing people write bug reports about. So the
    /// tail is what this is chosen on.
    ///
    /// This contradicts an earlier note in this file saying wsize=32768
    /// measured worse. That was measured against throughput alone, before
    /// dumbtimer was in force, and it is left standing as what it was: the
    /// same knob, a different question, and only one of them was about what a
    /// person sees.
    ///
    /// Reads stay at 131072. Nothing measured here says a large read hurts,
    /// and a copy off the drive wants them.
    ///
    /// 16384 was tried and is not better: median 6.99s, p90 15.92s, worst
    /// 20.37s, 6.8 MB/s -- a slightly better middle for a worse tail and a
    /// slower copy. 32768 is the knee, and halving again buys nothing.
    ///
    /// WHERE THE REMAINING SEVEN SECONDS GO, AND WHY NO OPTION REACHES THEM
    ///
    /// The median sits near seven seconds whatever the write size, so
    /// head-of-line blocking in the socket was part of it and not all of it.
    /// Every measurement now points the same way, and it is not the server:
    ///
    ///   the guest lists that directory in         0.01s
    ///   a GETATTR of a file in it, over NFS       0.03s
    ///   a quiet directory on the same mount       0.02s
    ///   the directory being written to            7s, and once 90s
    ///
    /// Server fast, RPC fast, other directories fast, this directory slow.
    /// What is different about it is that it has creates in flight, and the
    /// thing they share is the client's vnode for that one directory. A
    /// READDIR waits on it while ditto is making files in it; a GETATTR of a
    /// file underneath it is a different vnode and does not; the quiet
    /// directory is a different vnode and does not.
    ///
    /// That reading was wrong too, and the test that killed it is worth
    /// keeping. If a directory stalls because creates hold its vnode, then a
    /// directory receiving nothing but creates should stall hardest. Copy
    /// three thousand small files into one -- it grows continuously, a create
    /// every few milliseconds -- and list it throughout:
    ///
    ///     median 0.04s, worst 0.07s
    ///
    /// Creates do not do it. Only sustained large writes to a file inside the
    /// directory do. Which puts it back on the write stream: a READDIR queued
    /// behind bulk write RPCs on the one connection, exactly where the write
    /// size reaches it.
    ///
    /// And the thread pool was re-tested, because the reason it was first
    /// dismissed does not hold. That reason was "a quiet directory answers in
    /// 20 ms while the busy one waits seven seconds, so there is always a free
    /// thread" -- but a quiet directory is answered from the client's cache
    /// without an RPC at all, so it never asked the server anything. Asked
    /// properly, with 32 threads instead of 8 under the same copy:
    ///
    ///     32 threads   median 9.83s   p90 14.04s   worst 17.53s   7.0 MB/s
    ///      8 threads   median 8.36s   p90 11.18s   worst 16.56s   7.2 MB/s
    ///
    /// Worse on all four. The conclusion stands and now rests on something.
    ///
    /// So the floor is a READDIR waiting behind a saturated write stream, and
    /// the write size is the only knob measured to reach it: ninety seconds
    /// down to sixteen. The median near eight is what NFS costs here.
    public static let writeSize = 32768

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

    /// The two NTFS actions, as they are written into `config.toml`.
    ///
    /// Exposed rather than buried in the heredoc so that a harness driving the
    /// engine directly can install exactly what the app installs. The corpus
    /// harness asked the engine for `lukottantfs3` before this existed, the
    /// action was not in the config, the engine declined the attempt for that
    /// reason, and three damaged volumes came back reported as "refused and
    /// left untouched" -- a clean result produced by the check being absent.
    /// One source of truth, or the harness measures its own omissions.
    ///
    /// Both live or die together, on the same condition: a volume that is not
    /// NTFS has nothing for either to do, and one opened read-only is not
    /// written to at all. Generating them regardless would also put "-t ntfs3"
    /// into the script of every Linux mount.
    public static var microsoftActionsTOML: String {
        """
        [custom_actions.\(ntfs3ProbeActionName)]
        description = 'Generated by Lukotta; ntfs3 must pass a read-only probe first'
        \(guestEnvironment)
        before_mount = '\(nfsBlockSize); \(ntfs3Probe)'

        [custom_actions.\(repairActionName)]
        description = 'Generated by Lukotta; the same, and clears the dirty flag'
        \(guestEnvironment)
        before_mount = '\(nfsBlockSize); \(ntfsRepair)'
        """
    }

    private static func repairAction(
        configQ: String, actionQ: String, mergedQ: String, withRepair: Bool
    ) -> String {
        // Only where it can be reached. A drive opened read-only is not written
        // to at all, and ntfsfix is a write; a drive that is not NTFS has
        // nothing for it to do. Leaving the section out rather than leaving it
        // unused keeps that readable in the script itself.
        let repair = withRepair ? "\n" + microsoftActionsTOML : ""
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
                                   || $0 == "[custom_actions.\(ntfs3ProbeActionName)]" \\
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

    /// A mount asked for writable has to come back writable.
    ///
    /// ntfs-3g demotes itself. Handed a volume Windows left dirty it mounts it
    /// read-only, says so only in a line among many, and exits 0 -- so the
    /// engine reports success, the chain stops at that rung, and everything
    /// below it never runs. Including the repair.
    ///
    /// That is how the owner's drive came back read-only with no repair ever
    /// attempted. The transcript shows ntfs-3g correcting the volume in memory
    ///
    ///     Comparing $MFTMirr to $MFT... FAILED
    ///     Correcting differences in $MFTMirr record 3...OK
    ///     Processing of $MFT and $MFTMirr completed successfully.
    ///     Remount failed: I/O error
    ///
    /// and then settling for read-only. The repair rung, which would have run
    /// ntfsfix and cleared the dirty flag, sat one `||` further down and was
    /// never reached, because the rung above it had "succeeded".
    ///
    /// So a writable attempt now checks that what it produced is writable, and
    /// unmounts it if it is not, so the next rung starts from nothing. The
    /// read-only rung keeps the plain check: read-only is what it asked for.
    ///
    /// Asked by writing, which is the only question that cannot be answered
    /// wrongly. Two cheaper tests were tried first and both let a demoted
    /// mount through.
    ///
    /// Reading "read-only" out of the mount table did not fire: the word is
    /// not there at the instant the attempt returns.
    ///
    /// `[ -w ]` did not fire either, and that one is worth remembering. Asked
    /// from a shell as the owner it answers correctly -- not writable for the
    /// demoted mount, writable for a healthy one -- which is exactly how it
    /// was checked and exactly why it looked right. But this script runs as
    /// root inside the privileged daemon, and root's access(2) is not the same
    /// question. A test verified in one shell and deployed in another is not
    /// the same test.
    ///
    /// So it creates a file and removes it. A read-only mount refuses that for
    /// root as readily as for anyone, and nothing is left behind. It only ever
    /// runs on a mount that has just been produced by a writable attempt, so
    /// it writes to a volume only where writing was the whole intention. The
    /// mount-table test stays underneath it as a second opinion.
    private static let writableCheck = "__mounted_writable"

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
    ///
    /// `durability` is what this volume's own superblock says it needs, and
    /// nothing otherwise: ext4 and XFS both lose the contents of files that
    /// were fsynced before the machine died -- eight of eight wrong, measured
    /// here for each -- and each needs a different word to stop it. The option
    /// cannot go on blindly: an ext volume with no journal refuses to mount
    /// with `data=journal` at all, and the app passes no driver for Linux
    /// volumes, so anything added here would otherwise reach every one of them.
    /// See `ExtJournal.durabilityOption`.
    public static func mountOptions(
        driver: String?, readOnly: Bool, durability: String? = nil
    ) -> String {
        var opts = driverOptions(driver)
        // Never beside a driver. The drivers named here are the NTFS ones, and
        // this belongs to the Linux filesystems alone.
        // Never on a read-only mount. The option exists so that a write which
        // was fsynced survives the machine dying, and a volume opened read-only
        // takes no writes at all -- so it buys nothing and, on a device, `sync`
        // is the difference between 190 MB/s and 4.
        if let durability, driver == nil, !readOnly { opts.append(durability) }
        opts += readOnly ? ["ro"] : []
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
        durability: String? = nil,
        action: String? = tunedActionName
    ) -> String {
        let typeFlag = driver.map { " -t \($0)" } ?? ""
        let actionFlag = action.map { " -a \($0)" } ?? ""
        // --nfs-options must use the joined form. The flag is variadic, and the
        // separated form consumes the target that follows it.
        return "ALFS_PASSPHRASE=\"$__cred\" \(engineQ) mount\(ownership)"
            + "\(typeFlag)"
            + "\(mountOptions(driver: driver, readOnly: readOnly, durability: durability))"
            + "\(actionFlag) -w false"
            + "\(netHelper)"
            + " --nfs-options=\(shellQuoted(options))"
            + " \(target) >> \(logQ) 2>&1 && "
            + (readOnly ? mountedCheck : writableCheck)
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
        // It can be overridden from here, and the sentence that used to sit
        // here saying it could not was wrong. It claimed passing "hard" adds a
        // second key beside "soft" rather than replacing it. Both do reach the
        // command, but mount_nfs takes the last of the pair: mounting this
        // server by hand with "soft,intr,nolocks,hard" reports a mount whose
        // current parameters say "hard", with no "soft" among them. Ours are
        // the ones that land last, which is already how "timeo=600" beats the
        // engine's 100 in a mount table anyone can read.
        //
        // What that would buy is the whole class of failure rather than a
        // wider window: a hard mount does not fail a write because the server
        // was slow, so there is no error for Finder to end a copy on and no
        // half-written file for it to count as finished.
        //
        // It is not taken, and the reason is that the cost of being wrong is
        // not symmetric. The panic above is the claim that stands between here
        // and a hard mount, and the only experiment that settles it is pulling
        // a drive out from under one on somebody's machine. A failed copy is
        // recoverable and a panicked kernel mid-write is not, so the claim is
        // left standing until it can be tested somewhere it costs nothing.
        //
        // "timeo", "retrans" and "dumbtimer" are overridden instead, which is
        // measured rather than argued: see Inputs.nfsOptions.
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
