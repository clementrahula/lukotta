import Foundation
import LukottaCore

// A plain executable rather than XCTest or swift-testing: neither ships with
// the Command Line Tools, and requiring a full Xcode install to run the tests
// would put them out of reach of anyone building from source, and of CI.
var failures = 0, checks = 0, currentGroup = ""

func group(_ name: String, _ body: () -> Void) {
    currentGroup = name
    let before = failures
    body()
    print("  \(failures == before ? "ok  " : "FAIL") \(name)")
}

func expect(_ actual: String, _ expected: String, _ what: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print(
            "    FAIL [\(currentGroup)] \(what)\n      expected: \(expected)\n      actual:   \(actual)"
        )
    }
}

func expect(_ condition: Bool, _ what: String) {
    checks += 1
    if !condition { failures += 1; print("    FAIL [\(currentGroup)] \(what)") }
}

func sampleInputs(
    kind: VolumeKind = .microsoft,
    volume: LogicalVolume? = nil,
    alias: String? = "/tmp/ws/alias/Elements"
) -> MountScript.Inputs {
    MountScript.Inputs(
        enginePath:
            "/Applications/Lukotta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs",
        devicePath: "/dev/disk4s1",
        driveName: "Elements",
        kind: kind,
        volume: volume,
        aliasPath: alias,
        fifoPath: "/tmp/ws/credential.fifo",
        logPath: "/tmp/ws/mount.log",
        discoverLogPath: "/tmp/ws/discover.log",
        expectScriptPath: "/tmp/ws/discover.exp",
        configPath: "/Users/u/.anylinuxfs/config.toml",
        libraryPaths: ["/engine/lib"],
        uid: 501, gid: 20, cores: 4, ramMiB: 2560)
}

print("LukottaCore")

group("quotingTheseBuildACommandThatRunsAsRootSoTheyMatter") {

    expect(shellQuoted("/dev/disk4s1"), "'/dev/disk4s1'", "plain path quoting")
    expect(shellQuoted("/Volumes/My Drive"), "'/Volumes/My Drive'", "spaces survive quoting")
    expect(shellQuoted("it's"), #"'it'\''s'"#, "single quote is escaped")
    expect(shellQuoted("a; rm -rf /"), "'a; rm -rf /'", "shell metacharacters are neutralised")

    expect(appleScriptQuoted("plain"), "\"plain\"", "applescript plain")
    expect(appleScriptQuoted("say \"hi\""), "\"say \\\"hi\\\"\"", "applescript escapes quotes")
    expect(appleScriptQuoted("back\\slash"), "\"back\\\\slash\"", "applescript escapes backslash")
}

group("recoveryKeyHinting") {

    expect(Credential.hint(for: "") == nil, "empty input gives no hint")
    expect(Credential.hint(for: "hunter2") == nil, "a password gives no recovery-key hint")
    expect(
        Credential.hint(for: "121121-131131-141141-151151-161161-171171-181181-191191")
            == "Recovery key — 48 digits", "complete recovery key is recognised")
    expect(
        Credential.hint(for: "121121-131131-141141-151151")?.contains("24 of 48") == true,
        "partial recovery key reports progress")
    expect(Credential.hint(for: "1234") == nil, "short numeric input is treated as a password")
}

group("engineStatusParsing") {

    let statusSample = """
        /dev/disk4s1 on /Volumes/BACKUP (ntfs3, iocharset=utf8, uid=501, gid=20, mounted by someone) VM[cpus: 4, ram: 2048 MiB]
        """
    let parsed = EngineStatus.parse(statusSample)
    expect(parsed.count == 1, "one mount parsed")
    expect(parsed.first?.devicePath ?? "", "/dev/disk4s1", "device parsed")
    expect(parsed.first?.mountPoint ?? "", "/Volumes/BACKUP", "mount point parsed")

    let spacey = "/dev/disk9s2 on /Volumes/My Backup Drive (ntfs3, mounted by someone) VM[cpus: 2]"
    expect(
        EngineStatus.parse(spacey).first?.mountPoint ?? "", "/Volumes/My Backup Drive",
        "mount point with spaces parsed")
    expect(EngineStatus.parse("").isEmpty, "empty status yields no mounts")
    expect(EngineStatus.parse("garbage line without markers").isEmpty, "unparseable line ignored")

    // Image-backed mounts are reported with a file path rather than a device.
    let image =
        "/Users/someone/.lukotta-testvols/luks2-direct.img on /Users/someone/Volumes/DIRECTFS (btrfs, mounted by someone)"
    expect(
        EngineStatus.parse(image).first?.mountPoint ?? "", "/Users/someone/Volumes/DIRECTFS",
        "an image-backed mount is recognised")
}

group("failureDiagnosis") {

    expect(
        Diagnosis.summarise("cryptsetup: No key available with this passphrase.", fallback: ""),
        "That password or recovery key did not unlock this drive.", "wrong key diagnosis")
    expect(
        Diagnosis.summarise(
            "macOS: Error: Cannot probe /dev/disk4s1: LibErr(0); Insufficient permissions?",
            fallback: ""
        ).contains("Full Disk Access"),
        "TCC refusal diagnosis")
    expect(
        Diagnosis.summarise("error: device is already mounted", fallback: "").contains("already"),
        "already-mounted diagnosis")
    expect(
        Diagnosis.summarise("", fallback: "").isEmpty == false,
        "empty transcript still yields a sentence")
}

group("volumeKindsAndTheDirtyVolumePath") {

    expect(VolumeKind.microsoft.summary, "BitLocker or NTFS", "microsoft kind summary")
    expect(VolumeKind.linux.summary, "LUKS or Linux filesystem", "linux kind summary")

    let d = Drive(
        id: "disk4s1", devicePath: "/dev/disk4s1", name: "BACKUP",
        sizeBytes: 500_000_000_000, connection: "USB · External", kind: .microsoft,
        uuid: "7A2E4F10-3C58-4D9B-A6E1-2F7C05B34D88")
    expect(d.subtitle.contains("BitLocker or NTFS"), "subtitle states what the volume might be")
    expect(d.subtitle.contains("disk4s1"), "subtitle keeps the device identifier")

    // Windows Fast Startup and hibernation are the most common real-world failure,
    // and the advice has to be actionable rather than a raw driver error.
    let dirty = Diagnosis.summarise("ntfs3: volume is dirty and mounting is refused", fallback: "")
    expect(dirty.contains("Fast Startup"), "dirty volume explains Fast Startup")
    let hib = Diagnosis.summarise(
        "Windows is hibernated, refused to mount (hiberfile)", fallback: "")
    expect(hib.contains("Fast Startup"), "hibernated volume gets the same advice")
    expect(
        Diagnosis.summarise("mount: unknown filesystem type 'crypto_LUKS'", fallback: "")
            .contains("did not recognise"), "unrecognised filesystem diagnosis")
}

group("lvmDiscoveryFixtureCapturedFromARealLuks2LvmBtrfsVolume") {

    let vgSample = """
        /Users/someone/.lukotta-testvols/luks-lvm.img (disk image):
           #:                       TYPE NAME                    SIZE       IDENTIFIER
           0:                crypto_LUKS                        +629.1 MB   luks-lvm.img

        lvm:lukottavg (volume group):
           #:                       TYPE NAME                    SIZE       IDENTIFIER
           0:                LVM2_scheme                        +0.6 GB     lukottavg
                                         Physical Store luks-lvm.img
           1:                      btrfs LUKOTTATEST             608.2 MB   lukottavg:luks-lvm.img:data
        """
    let lvs = VolumeGroupParser.logicalVolumes(in: vgSample)
    expect(lvs.count == 1, "one mountable logical volume found (LVM2_scheme row ignored)")
    expect(
        lvs.first?.identifier ?? "", "lukottavg:luks-lvm.img:data", "vg:disk:lv identifier parsed")
    expect(
        lvs.first?.mountIdentifier ?? "", "lvm:lukottavg:luks-lvm.img:data",
        "mount identifier built")
    expect(lvs.first?.filesystem ?? "", "btrfs", "filesystem parsed")
    expect(lvs.first?.label ?? "", "LUKOTTATEST", "filesystem label parsed")
    expect(VolumeGroupParser.logicalVolumes(in: "").isEmpty, "no volume groups in empty output")
    expect(
        VolumeGroupParser.logicalVolumes(in: "   1:  crypto_LUKS  x  1 GB  a:b:c").isEmpty,
        "container types are not offered as mountable")
}

group("theElevatedMountScript") {

    // This text becomes a command run as root, and the mistakes it invites are
    // malformed arguments — none of which is reachable by a test while
    // generation and execution live in the same function.

    let msScript = MountScript.build(sampleInputs())

    // The regression that broke v1.1.0: --nfs-options is variadic, so the separated
    // form consumes the device path and the engine reports "mount with no disk".
    expect(!msScript.contains("-n '"), "NFS options must never use the separated form")
    expect(
        msScript.contains("--nfs-options='rsize=1048576,wsize=1048576,readahead=128'"),
        "NFS options use the joined form")
    expect(
        msScript.contains("'/dev/disk4s1' >>"),
        "the device is a positional argument, not swallowed by a preceding flag")

    // The credential is read from the pipe, never written into the script.
    expect(
        msScript.contains("__cred=\"$(cat '/tmp/ws/credential.fifo')\""),
        "credential is read from the FIFO")
    expect(msScript.contains("ALFS_PASSPHRASE=\"$__cred\""), "credential passed by reference")
    expect(msScript.contains("unset __cred"), "credential is unset afterwards")

    // Without these the engine refuses to run: it is root but not via sudo.
    expect(msScript.contains("export SUDO_UID=501"), "invoking uid exported")
    expect(msScript.contains("export SUDO_GID=20"), "invoking gid exported")
    expect(msScript.contains("export DYLD_LIBRARY_PATH='/engine/lib'"), "dyld path exported")

    // Microsoft volumes try the fast kernel driver, then the one that copes with a
    // dirty volume left by Windows Fast Startup.
    expect(msScript.contains("-t ntfs3"), "ntfs3 attempted")
    expect(msScript.contains("-t ntfs-3g"), "ntfs-3g attempted as fallback")
    expect(
        msScript.range(of: "-t ntfs3")!.lowerBound < msScript.range(of: "-t ntfs-3g")!.lowerBound,
        "ntfs3 is tried before ntfs-3g")
    expect(
        !msScript.contains("/usr/bin/expect"),
        "no LVM discovery for a Microsoft volume")

    // An alias cannot stand in for the device: the engine prefixes /dev/ onto
    // whatever target it is handed, so one under /tmp resolves to /dev//tmp/…
    // and the mount opens with "disk not found". Friendly names come from
    // DriveMemory, and only an alias already under /dev is worth passing.
    expect(!msScript.contains("alias/Elements"), "an unresolvable alias is not attempted")
    expect(msScript.contains("'/dev/disk4s1'"), "the device itself is what gets mounted")

    let msNoAlias = MountScript.build(sampleInputs(alias: nil))
    expect(msNoAlias.contains("'/dev/disk4s1'"), "device used when no alias is available")

    // Linux volumes: no driver override, and LVM discovery appended.
    let msLinux = MountScript.build(sampleInputs(kind: .linux))
    expect(!msLinux.contains("-t ntfs"), "no NTFS driver forced on a Linux volume")
    expect(msLinux.contains("expect -f '/tmp/ws/discover.exp'"), "discovery driven through expect")
    expect(msLinux.contains("\"lvm:$__lv\""), "each discovered volume is mounted by identifier")

    // A volume the user picked is mounted directly, with no discovery or override.
    let lv = LogicalVolume(
        identifier: "ubuntuvg:disk4s1:home", label: "HOMEFS",
        filesystem: "btrfs", size: "394 MB")
    let msChosen = MountScript.build(sampleInputs(kind: .linux, volume: lv))
    expect(msChosen.contains("'lvm:ubuntuvg:disk4s1:home'"), "chosen volume mounted by identifier")
    expect(!msChosen.contains("/usr/bin/expect"), "no rediscovery once chosen")
    expect(!msChosen.contains("-t ntfs"), "no driver override for a chosen volume")

    // Paths with spaces must survive quoting: they reach a root shell. The
    // workspace sits under a temporary directory the user does not choose, so
    // this is not hypothetical.
    let msSpaces = MountScript.build(
        MountScript.Inputs(
            enginePath: "/eng/any linux fs", devicePath: "/dev/disk4s1", driveName: "D",
            kind: .linux, volume: nil, aliasPath: nil, fifoPath: "/tmp/My Space/fifo",
            logPath: "/tmp/My Space/mount.log", discoverLogPath: "/tmp/My Space/discover.log",
            expectScriptPath: "/tmp/My Space/discover.exp",
            configPath: "/Users/u/.anylinuxfs/config.toml", libraryPaths: ["/eng/li b"],
            uid: 501, gid: 20, cores: 4, ramMiB: 2560))
    expect(msSpaces.contains("'/tmp/My Space/mount.log'"), "spaces in paths stay quoted")
    expect(msSpaces.contains("'/eng/any linux fs'"), "spaces in the engine path stay quoted")
    expect(msSpaces.contains("'/tmp/My Space/discover.exp'"), "spaces in the expect path quoted")
}

group("multiVolumeServing") {

    // All volumes of a container are served from the one microVM: the engine
    // holds an exclusive lock on the device for read-write mounts, so mounting
    // each volume in its own VM can never work. The script generates a custom
    // action that mounts every volume onto tmpfs inside the VM and exports the
    // lot, and only falls back to one-at-a-time if that combined mount fails.
    let script = MountScript.build(sampleInputs(kind: .linux))

    expect(script.contains("-a lukotta"), "the generated action is selected for the mount")
    expect(script.contains("\"lvm:$__first\""), "one volume carries the primary mount")
    expect(script.contains("[custom_actions.lukotta]"), "the action section is generated")
    expect(script.contains("'/run/Elements'"), "the export scratch dir is named after the drive")
    expect(
        script.contains(#"mount -o bind \"$ALFS_VM_MOUNT_POINT\""#),
        "the primary volume is bound into the scratch dir, not re-mounted")
    expect(
        script.contains("'/Users/u/.anylinuxfs/config.toml'"),
        "the action is merged into the engine's config")
    expect(
        script.contains("LUKOTTA_VOLUMES:$(/sbin/mount"),
        "a combined mount reports how many volumes actually appeared")
    expect(script.contains("\"lvm:$__lv\""), "the one-at-a-time fallback is still present")
    // Volumes that are not mountable filesystems would sink the combined
    // mount: its after_mount stops at the first failure, deliberately, so a
    // half-served drive cannot masquerade as the whole one.
    expect(script.contains("|swap|"), "swap volumes are excluded from serving")
    expect(script.contains("crypto_LUKS"), "nested encrypted volumes are excluded")

    // The scratch dir name reaches a root shell, a TOML file and Finder.
    expect(
        MountScript.exportName(driveName: "Elements", devicePath: "/dev/disk4s1"), "Elements",
        "a plain name is kept")
    expect(
        MountScript.exportName(driveName: "Samsung T7", devicePath: "/dev/disk4s1"),
        "Samsung-T7", "spaces are made shell- and marker-safe")
    expect(
        MountScript.exportName(driveName: "", devicePath: "/dev/disk4s1"), "disk4s1",
        "an unnamed drive falls back to the device")
    expect(
        MountScript.exportName(driveName: ".système; rm -rf /", devicePath: "/dev/disk4s1"),
        "syst-me--rm--rf--", "hostile names are neutralised and cannot hide the volume")
    expect(
        MountScript.exportName(driveName: "---", devicePath: "/dev/disk4s1"), "disk4s1",
        "a name that sanitises to nothing falls back to the device")
}

group("appRollback") {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let new = "1.7.0"
    let old = "1.6.9"

    // The property that makes a rollback impossible on an ordinary launch, and
    // it is structural: with nothing kept aside the count is never even read.
    expect(
        AppRollback.decide(record: nil, currentVersion: new, keptAside: nil, now: now)
            == .proceed(nil),
        "an ordinary launch is not counted, because there is nothing to go back to")
    expect(
        AppRollback.decide(
            record: LaunchRecord(version: new, attempts: 99, firstAttemptAt: now),
            currentVersion: new, keptAside: nil, now: now) == .proceed(nil),
        "a stale record without a kept-aside copy is cleared, not acted on")

    // The kept-aside copy being what is running means the install never
    // happened, or a rollback already put this version back.
    expect(
        AppRollback.decide(record: nil, currentVersion: old, keptAside: old, now: now)
            == .proceed(nil),
        "nothing to undo when the kept-aside version is the one running")

    // A first failed launch is not evidence: a power cut and a force quit leave
    // exactly this trace.
    guard
        case .proceed(let first) = AppRollback.decide(
            record: nil, currentVersion: new, keptAside: old, now: now)
    else { return expect(false, "a first attempt proceeds") }
    expect(first?.attempts == 1, "the first attempt is counted but allowed")

    guard
        case .proceed(let second) = AppRollback.decide(
            record: first, currentVersion: new, keptAside: old, now: now.addingTimeInterval(60))
    else { return expect(false, "a second attempt proceeds") }
    expect(second?.attempts == 2, "the second is counted and still allowed")
    expect(second?.firstAttemptAt == now, "the first attempt's time is kept")

    expect(
        AppRollback.decide(
            record: second, currentVersion: new, keptAside: old, now: now)
            == .rollBack(attempts: 3),
        "the third puts the previous version back")

    // A different version starts the count again, so failures of one build are
    // not counted against the next.
    guard
        case .proceed(let other) = AppRollback.decide(
            record: LaunchRecord(version: "1.5.0", attempts: 2, firstAttemptAt: now),
            currentVersion: new, keptAside: old, now: now)
    else { return expect(false, "a record for another version proceeds") }
    expect(other?.attempts == 1, "a record of another version does not carry over")

    group("engineConfigCleanup") {

        // The generated action must be removable without touching anything else in
        // the engine's config, which also holds the user's own settings.
        let config = """
            [alpine]
            custom_packages = []

            [custom_actions.lukotta]
            description = 'Generated by Lukotta; removed after ejecting'
            after_mount = 'set -eu; mkdir -p /run/T7'
            override_nfs_export = '/run/T7'
            nfs_export_subdirs = ["ROOT", "HOME"]

            [custom_actions.mine]
            description = 'the user wrote this one'

            [krun]
            num_vcpus = 4
            """
        let cleaned = EngineConfig.withoutGeneratedAction(config)
        expect(!cleaned.contains("[custom_actions.lukotta]"), "the generated section is removed")
        expect(!cleaned.contains("override_nfs_export"), "its body goes with it")
        expect(cleaned.contains("[custom_actions.mine]"), "a user-written action survives")
        expect(cleaned.contains("the user wrote this one"), "with its body")
        expect(cleaned.contains("num_vcpus = 4"), "engine settings survive")
        expect(EngineConfig.withoutGeneratedAction(cleaned) == cleaned, "removal is idempotent")

        // The section may sit at the end of the file, with no header after it.
        let atEnd = "[krun]\nnum_vcpus = 4\n\n[custom_actions.lukotta]\nafter_mount = 'x'"
        let cleanedEnd = EngineConfig.withoutGeneratedAction(atEnd)
        expect(!cleanedEnd.contains("lukotta"), "a trailing section is removed")
        expect(cleanedEnd.contains("num_vcpus = 4"), "what precedes it survives")
        expect(
            EngineConfig.withoutGeneratedAction("[krun]\nnum_vcpus = 4") == "[krun]\nnum_vcpus = 4",
            "a config without the section is untouched")
    }
}

group("nestedVolumeMounts") {

    // The engine's status reports only the primary mount of a multi-volume
    // drive; the per-volume NFS mounts nested under it come from the system
    // mount table.
    let table = """
        /dev/disk3s5 on / (apfs, sealed, local, read-only, journaled)
        lvm-fedoravg.local:/run/T7 on /Volumes/T7 (nfs, nodev, nosuid, mounted by someone)
        lvm-fedoravg.local:/run/T7/ROOT on /Volumes/T7/ROOT (nfs, nodev, nosuid, mounted by someone)
        lvm-fedoravg.local:/run/T7/HOME on /Volumes/T7/HOME (nfs, nodev, nosuid, mounted by someone)
        /dev/disk5s1 on /Volumes/T7ish (apfs, local, journaled)
        """
    let nested = EngineStatus.nestedVolumes(under: "/Volumes/T7", in: table)
    expect(nested == ["/Volumes/T7/ROOT", "/Volumes/T7/HOME"], "nested NFS mounts found in order")
    expect(
        EngineStatus.nestedVolumes(under: "/Volumes/T7", in: "").isEmpty,
        "an empty table yields nothing")
    expect(
        !EngineStatus.nestedVolumes(under: "/Volumes/T7", in: table).contains("/Volumes/T7ish"),
        "a sibling with a shared prefix is not mistaken for a nested volume")

    // The scratch export lives under /run, so those mounts are the engine's
    // to clear when their VM dies — but not while it is alive.
    let claimed = EngineStatus.engineMountPoints(in: table)
    expect(claimed.contains("/Volumes/T7"), "a multi-volume primary is recognised as ours")
    expect(claimed.contains("/Volumes/T7/HOME"), "and so are its nested volumes")
    expect(!claimed.contains("/Volumes/T7ish"), "a local disk is not")

    // Multi-volume mounts are reported with an lvm: source, which must still
    // be recognised or an open drive would not be resumed after a relaunch.
    let status = """
        lvm:fedoravg:disk5s1:root on /Volumes/T7 (btrfs, mounted by someone) VM[cpus: 4, ram: 2560 MiB]
        """
    let parsed = EngineStatus.parse(status)
    expect(parsed.count == 1, "an lvm-backed mount is reported")
    expect(parsed.first?.mountPoint ?? "", "/Volumes/T7", "its mount point is parsed")
}

group("mountStages") {
    // The engine exits 0 on a failed mount: the status is its own shutdown, not
    // the mount's. Every fallback is chained with ||, so a mount attempt has to
    // be judged by whether a mount appeared, not by what the engine returned.
    // Without this the first attempt always looked like a success and nothing
    // after it ever ran — no ntfs-3g retry, no LVM discovery.
    let checked = MountScript.build(sampleInputs(kind: .linux))
    expect(
        checked.contains("__mounts=$(/sbin/mount | grep -cE ':/(mnt|run)/')"),
        "a baseline is taken")
    expect(
        checked.contains(
            """
            2>&1 && [ "$(/sbin/mount | grep -cE ':/(mnt|run)/')" -gt "$__mounts" ]
            """.trimmingCharacters(in: .whitespacesAndNewlines)),
        "an attempt counts as success only if a mount appeared")
    // Counting, not name matching: the share is named for the device on a plain
    // volume but for the volume group on an LVM one, so there is no one name.
    expect(!checked.contains("disk4s1.local:"), "the check does not guess the share's name")
    let checkedMS = MountScript.build(sampleInputs(kind: .microsoft))
    expect(
        checkedMS.components(separatedBy: "-gt \"$__mounts\"").count - 1 == 2,
        "both NTFS driver attempts are verified, so the retry can be reached")

    // A pty echoes what is written to it, so the engine's own output can carry
    // the passphrase back. Shape-matching cannot catch an ordinary one, so the
    // value itself is removed when it is known.
    let leak = "Enter passphrase for /dev/disk4s1:\nhunter2-correct-horse\nunlocked"
    let scrubbed = Diagnostics.redact(leak, secret: "hunter2-correct-horse")
    expect(!scrubbed.contains("hunter2-correct-horse"), "an echoed passphrase is removed")
    expect(scrubbed.contains("unlocked"), "the rest of the output survives")
    expect(
        Diagnostics.redact("a mount failed", secret: "ab").contains("a mount failed"),
        "a secret too short to be one does not eat ordinary output")
    expect(
        Diagnostics.redact("nothing secret here", secret: nil) == "nothing secret here",
        "no secret means no change")
    // The shape rules still apply on top, for output whose secret is unknown.
    expect(
        !Diagnostics.redact(
            "key 100000-200000-300000-400000-500000-600000-700000-800000",
            secret: nil
        ).contains("100000-200000"),
        "a recovery key is still caught by shape")

    // The script is assembled from strings, quoted by hand, and run as root. A
    // single apostrophe inside the awk program once closed its quote and made
    // every multi-volume mount fail with no output at all, so the shell's own
    // parser is the judge of whether it is valid.
    for kind in [VolumeKind.linux, .microsoft] {
        let generated = MountScript.build(sampleInputs(kind: kind))
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lukotta-script-\(kind.rawValue).sh")
        try? generated.write(to: file, atomically: true, encoding: .utf8)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", file.path]
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        expect(check.terminationStatus == 0, "the \(kind.rawValue) script is valid shell")
        try? FileManager.default.removeItem(at: file)
    }

    // Discovery is driven through expect, which uses a pty, so its output is
    // CRLF. Left in place the carriage return joins the identifier and the
    // mount names a block device that cannot exist.
    expect(checked.contains("tr -d '\\r'"), "carriage returns are stripped from discovery")
    expect(
        checked.range(of: "tr -d '\\r'")!.lowerBound < checked.range(of: "__lvs=$(awk")!.lowerBound,
        "stripped before the identifiers are read out")

    // Every volume found is opened, rather than asking which one is wanted.
    expect(checked.contains("for __lv in $__lvs; do"), "each discovered volume is mounted")
    expect(checked.contains("[ \"$__opened\" -gt 0 ]"), "opening any one of them is a success")

    // Taken from a real failure on a Fedora-style container: LUKS holding LVM
    // holding three volumes. The engine refuses to mount the container itself,
    // and the app has to turn that into a question rather than a failure.
    let lvmTranscript = """
        \(MountScript.stageMarker)authorised
        macOS: fs_type: Some("crypto_LUKS")
        Linux:   3 logical volume(s) in volume group "fedoravg" now active
        Linux: Error: `LVM2_member` partition cannot be mounted directly.
        macOS: libkrun VM exited with status: 1
        macOS: gvproxy exited with status: 0
        """
    expect(
        !Diagnosis.summarise(lvmTranscript, fallback: "").contains("gvproxy"),
        "an orderly shutdown is not what went wrong")
    expect(
        Diagnosis.summarise(lvmTranscript, fallback: "").contains("several volumes"),
        "a container holding volumes is explained as such")
    expect(
        !Diagnostics.withoutMarkers(lvmTranscript).contains(MountScript.stageMarker),
        "step markers are stripped from anything the user reads")
    expect(
        Diagnostics.withoutMarkers(lvmTranscript).contains("crypto_LUKS"),
        "stripping markers keeps the engine's own output")

    // The volume list the engine prints once discovery has run.
    let listing = """
        lvm:fedoravg (volume group):
           #:            TYPE NAME             SIZE       IDENTIFIER
           0:     LVM2_scheme                  +0.9 GB    fedoravg
           1:           btrfs FEDORAROOT       252.0 MB   fedoravg:disk5s1:root
           2:           btrfs FEDORAHOME       252.0 MB   fedoravg:disk5s1:home
           3:           btrfs FEDORABACKUP     376.0 MB   fedoravg:disk5s1:backup
        """
    let lvs = VolumeGroupParser.logicalVolumes(in: listing)
    expect(lvs.count == 3, "three logical volumes are found, the scheme row is not one")
    expect(lvs.map(\.label) == ["FEDORAROOT", "FEDORAHOME", "FEDORABACKUP"], "labels are read")
    expect(
        lvs.first?.mountIdentifier == "lvm:fedoravg:disk5s1:root",
        "the engine's own lvm: form is what gets mounted")

    // An alias outside /dev cannot resolve, so it must not become an attempt.
    let aliased = MountScript.build(
        MountScript.Inputs(
            enginePath: "/e", devicePath: "/dev/disk5s1", driveName: "D", kind: .linux,
            volume: nil, aliasPath: "/tmp/ws/alias/Disk Image", fifoPath: "/f",
            logPath: "/l", discoverLogPath: "/d", expectScriptPath: "/x",
            configPath: "/c", libraryPaths: [], uid: 501, gid: 20, cores: 4, ramMiB: 2560))
    expect(!aliased.contains("/tmp/ws/alias"), "an unresolvable alias is not attempted")
    expect(aliased.contains("'/dev/disk5s1'"), "the device itself still is")

    // A mount left behind by a dead virtual machine has to be recognisable
    // without touching anything the user mounted themselves: clearing one of
    // those would be a far worse bug than the one this fixes.
    let table = """
        /dev/disk1s1 on / (apfs, sealed, local, read-only, journaled)
        disk4s1.local:/mnt/BACKUP on /Volumes/BACKUP (nfs, nodev, nosuid, mounted by someone)
        //someone@nas.local/media on /Volumes/media (smbfs, nodev, nosuid)
        fileserver:/exports/home on /Volumes/home (nfs, nodev, nosuid)
        map auto_home on /System/Volumes/Data/home (autofs, automounted)
        """
    let engineMounts = EngineStatus.engineMountPoints(in: table)
    expect(engineMounts == ["/Volumes/BACKUP"], "only the engine's own NFS mount is claimed")
    expect(!engineMounts.contains("/Volumes/media"), "an SMB share of the user's is left alone")
    expect(!engineMounts.contains("/Volumes/home"), "an unrelated NFS share is left alone")
    expect(EngineStatus.engineMountPoints(in: "").isEmpty, "an empty mount table claims nothing")

    // Stages come from markers the script writes. The engine prints almost
    // nothing while mounting, so inferring them from its output left the
    // indicator stuck on one step and then jumping — the bug this replaces.
    let marker = MountScript.stageMarker
    expect(MountStage.inferred(from: []) == .preparing, "nothing yet means preparing")
    expect(
        MountStage.inferred(from: ["Waiting for your administrator approval…"]) == .authorising,
        "approval reported by the app")
    expect(
        MountStage.inferred(from: ["\(marker)authorised"]) == .authorising,
        "authorisation marker recognised")
    expect(
        MountStage.inferred(from: ["\(marker)authorised", "\(marker)working"]) == .working,
        "work started once the credential has been read")
    expect(
        MountStage.inferred(from: ["\(marker)working", "mounted on /Volumes/BACKUP"]) == .finishing,
        "a mount point means it is being handed to Finder")
    expect(
        MountStage.inferred(from: ["mounted on /Volumes/BACKUP", "\(marker)authorised"])
            == .finishing,
        "stages never go backwards")

    // The helper redacts its transcript before handing it back, and the same
    // text is what drives the step indicator. Redaction that mangled a marker
    // would leave the steps stuck without anything looking wrong.
    for stage in ["authorised", "working"] {
        expect(
            Diagnostics.redact("\(marker)\(stage)").contains("\(marker)\(stage)"),
            "redaction leaves the \(stage) marker intact")
    }

    // The markers are plumbing and must not be shown as engine output.
    let script = MountScript.build(sampleInputs())
    expect(script.contains("\(marker)authorised"), "script announces authorisation")
    expect(script.contains("\(marker)working"), "script announces that work began")
}

group("markdownRendering") {
    // The notices are shown in-app; dumping raw Markdown at a reader is what
    // this replaces, so the parser has to actually handle what the file uses.
    let doc = """
        # Third-party notices

        Lukotta is licensed **GPL-3.0-or-later**.

        ## Host components

        | Component | Licence |
        | --- | --- |
        | anylinuxfs | GPL-3.0-or-later |
        | Linux kernel | GPL-2.0-only |

        - First point
        - Second point
        """
    let blocks = MarkdownDocument.parse(doc)

    var headings = 0, paragraphs = 0, tables = 0, bullets = 0
    for b in blocks {
        switch b {
        case .heading: headings += 1
        case .paragraph: paragraphs += 1
        case .table(let header, let rows):
            tables += 1
            expect(header == ["Component", "Licence"], "table header parsed")
            expect(rows.count == 2, "alignment row is not treated as data")
            expect(rows.first == ["anylinuxfs", "GPL-3.0-or-later"], "table cells parsed")
        case .bullets(let items):
            bullets += 1
            expect(items == ["First point", "Second point"], "bullets parsed")
        }
    }
    expect(headings == 2, "both headings parsed")
    expect(paragraphs == 1, "paragraph parsed")
    expect(tables == 1, "table parsed")
    expect(bullets == 1, "bullet list parsed")
    expect(MarkdownDocument.parse("").isEmpty, "empty document yields no blocks")

    // A wrapped bullet is one bullet, not a bullet plus a loose paragraph.
    let wrapped = """
        - First item that runs on
          across two source lines
        - Second item
        """
    let wrappedBlocks = MarkdownDocument.parse(wrapped)
    expect(wrappedBlocks.count == 1, "a wrapped list produces one block")
    if case .bullets(let items) = wrappedBlocks[0] {
        expect(items.count == 2, "two items, not three blocks")
        expect(
            items[0] == "First item that runs on across two source lines",
            "the continuation joins its own bullet")
    } else {
        expect(false, "expected a bullet list")
    }
}

group("secretRedaction") {
    // Engine output is shown in the app, kept in the workspace, and offered in
    // bug reports. Nothing credential-shaped may survive any of those paths.
    let key = "121121-131131-141141-151151-161161-171171-181181-191191"
    let redactedGrouped = Diagnostics.redact("Enter passphrase: \(key) ok")
    expect(!redactedGrouped.contains("121121"), "grouped recovery key is removed")
    expect(!redactedGrouped.contains(key), "the full key never survives")

    let run = "121121131131141141151151161161171171181181191191"
    expect(
        !Diagnostics.redact("key was \(run)").contains(run),
        "an unseparated 48-digit key is removed")

    expect(
        !Diagnostics.redact("ALFS_PASSPHRASE=hunter2").contains("hunter2"),
        "a labelled secret is removed whatever its shape")
    expect(
        !Diagnostics.redact("password: correct horse").contains("correct"),
        "a labelled password is removed")

    // Ordinary diagnostics must survive, or redaction makes reports useless.
    let ordinary = "mount: /dev/disk4s1 on /Volumes/BACKUP (ntfs3) 500.07 GB"
    expect(Diagnostics.redact(ordinary) == ordinary, "normal output is untouched")
    expect(
        Diagnostics.redact("Lukotta 1.5.0 build 52").contains("1.5.0"),
        "version numbers are not mistaken for secrets")

    // The report itself must be clean even when handed raw output.
    let env = Diagnostics.environment()
    let report = Diagnostics.report(
        environment: env, problem: "tried \(key)",
        engineOutput: "passphrase: \(key)")
    expect(!report.contains("121121"), "the assembled report carries no key")
}

group("crashReportFiltering") {
    // A crash from an older build, offered beside an unrelated failure, reads
    // as "this just crashed". That is how a cancelled authorisation came to
    // look like a crash.
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    if let found = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
        let sample = found.first(where: { $0.hasPrefix("Lukotta") && $0.hasSuffix(".ips") })
    {
        let url = dir.appendingPathComponent(sample)
        let build = Diagnostics.buildRecorded(in: url)
        expect(build != nil, "a build number is read from the report header")
        expect(build.map { !$0.isEmpty } ?? false, "the build number is not empty")
    }

    // Nothing is offered when no report matches, which is the normal case.
    let none = Diagnostics.crashReports(appName: "NoSuchApplication")
    expect(none.isEmpty, "no reports for an application that has never crashed")
}

group("driveMemory") {
    // The volume label is only knowable after unlocking, which is after the
    // share has been named. Remembering it is what lets the next unlock show
    // "BACKUP" instead of "disk4s1.local".
    let uuid = "lukotta-memory-test-\(UUID().uuidString)"
    expect(DriveMemory.knownName(for: uuid) == nil, "nothing known about a new drive")

    DriveMemory.remember(mountPoint: "/Volumes/BACKUP", for: uuid)
    expect(DriveMemory.knownName(for: uuid) == "BACKUP", "the label is remembered")

    DriveMemory.remember(mountPoint: "/Users/someone/Volumes/Field Recorder", for: uuid)
    expect(DriveMemory.knownName(for: uuid) == "Field Recorder", "a later mount replaces it")

    DriveMemory.remember(mountPoint: "/", for: uuid)
    expect(DriveMemory.knownName(for: uuid) == "Field Recorder", "a meaningless path is ignored")

    DriveMemory.forget(uuid: uuid)
    expect(DriveMemory.knownName(for: uuid) == nil, "forgetting removes it")
    expect(DriveMemory.knownName(for: "") == nil, "an empty identifier is refused")
}

group("keychainRoundTrip") {
    // A saved credential that cannot be read back is worse than not offering
    // to save it: the user believes it is stored.
    let uuid = "lukotta-test-\(UUID().uuidString)"
    let secret = "121121-131131-141141-151151-161161-171171-181181-191191"

    expect(CredentialStore.load(for: uuid) == nil, "nothing stored for a fresh identifier")
    let saved = CredentialStore.save(secret, for: uuid)
    expect(saved, "save reports success")
    expect(CredentialStore.load(for: uuid) == secret, "the credential reads back unchanged")
    expect(CredentialStore.has(for: uuid), "presence is reported")

    // Saving again must replace rather than fail on a duplicate.
    expect(CredentialStore.save("second", for: uuid), "re-saving replaces")
    expect(CredentialStore.load(for: uuid) == "second", "the replacement is what reads back")

    CredentialStore.delete(for: uuid)
    expect(CredentialStore.load(for: uuid) == nil, "deletion removes it")
    expect(!CredentialStore.has(for: uuid), "presence is false after deletion")

    expect(!CredentialStore.save("x", for: ""), "an empty identifier is refused")
}

group("clientRequirement") {
    // The requirement is now built at run time from the helper's own signing
    // team, so it is code rather than a constant and can be got wrong.
    let team = "A1B2C3D4E5"

    let text = HelperInfo.clientRequirement(team: team)
    expect(text != nil, "a well formed team yields a requirement")
    expect(text?.contains("anchor apple generic") == true, "the anchor is still pinned")
    expect(
        text?.contains("certificate leaf[subject.OU] = \"\(team)\"") == true,
        "the team is pinned")
    expect(
        text?.contains("identifier \"\(HelperInfo.appIdentifier)\"") == true,
        "the identifier is pinned to this bundle")

    // A quote or a space would end the identifier early and change what the
    // requirement means, so neither may reach the parser.
    expect(HelperInfo.clientRequirement(team: "AB\" or anything") == nil, "a quote is refused")
    expect(HelperInfo.clientRequirement(team: "AB CD") == nil, "a space is refused")
    expect(HelperInfo.clientRequirement(team: "") == nil, "an empty team is refused")
    expect(
        HelperInfo.clientRequirement(team: String(repeating: "A", count: 256)) == nil,
        "an absurdly long team is refused")

    expect(HelperInfo.isWellFormed("com.example.drive-unlocker_1"), "ordinary identifiers pass")
    expect(!HelperInfo.isWellFormed("com.example/../evil"), "a path separator is refused")

    // Every name the app and the daemon use has to agree on one identifier.
    expect(
        HelperInfo.machServiceName == "\(HelperInfo.appIdentifier).helper",
        "the service name derives from the identifier")
    expect(
        HelperInfo.plistName == "\(HelperInfo.machServiceName).plist",
        "the daemon plist name derives from the service name")
}

group("guestRuntimeSync") {
    let now = Date()
    let older = now.addingTimeInterval(-3600)

    // The engine's own test: size first, then "is the bundled one newer".
    expect(
        GuestRuntime.needsSync(
            bundledSize: 100, bundledModified: older, guestSize: 101, guestModified: now),
        "a different size means the guest copy is stale")
    expect(
        GuestRuntime.needsSync(
            bundledSize: 100, bundledModified: now, guestSize: 100, guestModified: older),
        "a newer bundled file means the guest copy is stale")
    expect(
        !GuestRuntime.needsSync(
            bundledSize: 100, bundledModified: older, guestSize: 100, guestModified: now),
        "an older bundled file leaves the guest copy alone")

    // Copying keeps the timestamp, so the two match exactly afterwards. That
    // has to read as settled, or every launch would copy again.
    expect(
        !GuestRuntime.needsSync(
            bundledSize: 100, bundledModified: now, guestSize: 100, guestModified: now),
        "matching size and timestamp is settled, not stale")

    // The raw engine string is not something to show anyone.
    let advice = Diagnosis.summarise(
        "macOS: Error: another instance is already running", fallback: "x")
    expect(advice.contains("Eject the other drives"), "the lock clash says what to do")
    expect(!advice.contains("another instance"), "and does not repeat the engine's wording")
}

group("wakeRecovery") {
    // Waking is not one moment: the host comes back before the microVM does,
    // and the mount cannot answer until the network between them carries
    // traffic again. Asking once and giving up would call every healthy drive
    // dead.
    expect(WakeRecovery.nextDelay(after: 0) != nil, "a mount is asked more than once")

    // Doubling, so a wedged mount is not asked sixty times for sixty seconds.
    let first = WakeRecovery.nextDelay(after: 0) ?? 0
    let later = WakeRecovery.nextDelay(after: 20) ?? 0
    expect(later > first, "the wait grows as the silence goes on")
    expect(WakeRecovery.nextDelay(after: 100) ?? 0 <= 16, "and stops growing")

    // The grace period is a ceiling, not a suggestion: a delay that runs past
    // it would leave a dead mount in the list longer than it says.
    expect(WakeRecovery.nextDelay(after: WakeRecovery.grace) == nil, "and then it gives up")
    expect(
        WakeRecovery.nextDelay(after: WakeRecovery.grace - 1) ?? 99 <= 1,
        "the last wait stops at the grace period rather than overshooting it")

    // Walk it the way the caller does, to prove it terminates.
    var elapsed: TimeInterval = 0, rounds = 0
    while let delay = WakeRecovery.nextDelay(after: elapsed), rounds < 1000 {
        elapsed += delay
        rounds += 1
    }
    expect(rounds < 1000, "the loop ends")
    expect(elapsed <= WakeRecovery.grace, "having waited no longer than the grace period")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("PASS: LukottaCore")
