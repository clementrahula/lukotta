import Foundation
import LukottaCore

// A plain executable rather than XCTest or swift-testing: neither ships with
// the Command Line Tools, and requiring a full Xcode install to run the tests
// would put them out of reach of anyone building from source, and of CI.
var failures = 0, checks = 0, currentGroup = ""

// Top-level code is on the main actor, so the state these keep is too.
@MainActor
func group(_ name: String, _ body: @MainActor () -> Void) {
    currentGroup = name
    let before = failures
    body()
    print("  \(failures == before ? "ok  " : "FAIL") \(name)")
}

@MainActor
func expect(_ actual: String, _ expected: String, _ what: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print(
            "    FAIL [\(currentGroup)] \(what)\n      expected: \(expected)\n      actual:   \(actual)"
        )
    }
}

@MainActor
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

group("reportLogTail") {
    // A report that silently begins in the middle reads as though nothing
    // happened before it, so a truncated log says it was truncated.
    let short = ["one", "two"]
    expect(Diagnostics.tail(of: short, limit: 5), "one\ntwo", "nothing is said when nothing is cut")

    let long = (1...10).map { "line \($0)" }
    let cut = Diagnostics.tail(of: long, limit: 3)
    expect(cut.contains("7 earlier lines not shown"), "the count of what was dropped is stated")
    expect(cut.hasSuffix("line 8\nline 9\nline 10"), "and the newest lines are the ones kept")
    expect(!cut.contains("line 7"), "the dropped ones are gone")

    // The report carries the log through the same redaction as everything
    // else: a passphrase echoed by the pty must not reach it by this route.
    let environment = Diagnostics.environment()
    let body = Diagnostics.report(
        environment: environment,
        recentLog: "mount password: hunter2000\n123456-123456-123456-123456-123456")
    expect(body.contains("What the app was doing:"), "the log is a section of its own")
    expect(!body.contains("hunter2000"), "a labelled secret in the log is redacted")
    expect(!body.contains("123456-123456"), "and so is a recovery key")

    // Nothing to say is not a heading with nothing under it.
    let empty = Diagnostics.report(environment: environment, recentLog: "")
    expect(!empty.contains("What the app was doing:"), "an empty log adds no section")
}

group("theLogIsReadableBack") {
    // The point of logging is a report that says what happened. That only
    // works if what was written can be found again, under the same subsystem
    // it was written to — a report reading one name and the logger writing
    // another would be silently empty forever.
    let marker = "log round trip \(ProcessInfo.processInfo.processIdentifier)"
    Log.app.notice("\(marker, privacy: .public)")
    // The store is written to asynchronously; give it a moment to land.
    Thread.sleep(forTimeInterval: 0.5)
    let text = Diagnostics.recentLog(within: 60)
    expect(text.contains(marker), "a line just written is found again")
    expect(text.contains("app"), "and carries the category it was written under")
}

group("driveScannerParsing") {
    // Shaped like `diskutil list -plist physical`, with invented names: what
    // matters is which partitions are picked up and what they end up called.
    let list: [String: Any] = [
        "AllDisksAndPartitions": [
            // The internal disk. Nothing on it is ours.
            [
                "DeviceIdentifier": "disk0",
                "Content": "GUID_partition_scheme",
                "Partitions": [
                    ["DeviceIdentifier": "disk0s1", "Content": "Apple_APFS_ISC"],
                    ["DeviceIdentifier": "disk0s2", "Content": "Apple_APFS"],
                ],
            ],
            // A USB drive holding one Windows partition.
            [
                "DeviceIdentifier": "disk4",
                "Content": "GUID_partition_scheme",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk4s1",
                        "Content": "Microsoft Basic Data",
                        "Size": NSNumber(value: 500_072_185_856),
                        "DiskUUID": "AAAAAAAA-0000-0000-0000-000000000001",
                    ]
                ],
            ],
            // A Linux drive with LVM, and a partition macOS knows nothing about.
            [
                "DeviceIdentifier": "disk5",
                "Content": "GUID_partition_scheme",
                "Partitions": [
                    ["DeviceIdentifier": "disk5s1", "Content": "EFI"],
                    [
                        "DeviceIdentifier": "disk5s2", "Content": "Linux LVM",
                        "Size": NSNumber(value: 1_000),
                    ],
                ],
            ],
            // A disk with no partition list at all, which must not throw.
            ["DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme"],
        ]
    ]
    let info: [String: [String: Any]] = [
        "disk4": [
            "MediaName": "Elements 25A2", "BusProtocol": "USB", "Internal": false,
        ],
        "disk5": [
            "IORegistryEntryName": "Generic Media", "BusProtocol": "USB", "Internal": false,
        ],
    ]
    let found = DriveScanner.drives(inList: list, info: { info[$0] ?? [:] })

    expect("\(found.count)", "2", "only the partitions we can do something with are listed")
    expect(found.map(\.id).joined(separator: ","), "disk4s1,disk5s2", "in the order they appear")

    let windows = found[0]
    expect(windows.devicePath, "/dev/disk4s1", "the device path is built from the identifier")
    expect(windows.name, "Elements 25A2", "an unnamed volume takes the drive's product name")
    expect("\(windows.kind)", "microsoft", "Microsoft Basic Data is the BitLocker-or-NTFS kind")
    expect(windows.uuid, "AAAAAAAA-0000-0000-0000-000000000001", "the partition UUID is kept")
    expect(windows.connection.contains("USB"), "the bus is part of the connection")
    expect(windows.connection.contains("External"), "and so is where the drive sits")

    let linux = found[1]
    expect("\(linux.kind)", "linux", "Linux LVM is the LUKS-or-Linux kind")
    expect(
        linux.name, "Generic Media", "falling back to the registry name when there is no media name"
    )
    // No UUID anywhere, so the identifier stands in — it has to be something,
    // and a drive with no identity at all cannot be remembered.
    expect(linux.uuid, "disk5s2", "a partition with no UUID is identified by its device")

    // Every Linux type diskutil reports, in both spellings.
    for content in [
        "Linux Filesystem", "Linux_Filesystem", "Linux LVM", "Linux_LVM",
        "Linux RAID", "Linux_RAID",
    ] {
        let one: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk9",
                    "Partitions": [["DeviceIdentifier": "disk9s1", "Content": content]],
                ]
            ]
        ]
        let drives = DriveScanner.drives(inList: one, info: { _ in [:] })
        expect("\(drives.count)", "1", "\(content) is recognised")
    }

    // The volume's own name wins over the drive's, and the size can come from
    // either plist — the list omits it for some partitions.
    let named: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk7",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk7s1", "Content": "Microsoft Basic Data",
                        "VolumeName": "BACKUP",
                    ]
                ],
            ]
        ]
    ]
    let one = DriveScanner.drives(
        inList: named,
        info: {
            $0 == "disk7s1"
                ? ["TotalSize": NSNumber(value: 42), "VolumeUUID": "BBBB"]
                : ["MediaName": "Some Drive"]
        })
    expect(one[0].name, "BACKUP", "a labelled volume is called what it is called")
    expect("\(one[0].sizeBytes)", "42", "the size falls back to the partition's own plist")
    expect(one[0].uuid, "BBBB", "and so does the identity")

    // A whitespace-only name is not a name.
    let blank: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk8",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk8s1", "Content": "Microsoft Basic Data",
                        "VolumeName": "   ",
                    ]
                ],
            ]
        ]
    ]
    expect(
        DriveScanner.drives(inList: blank, info: { _ in [:] })[0].name, "disk8s1",
        "with nothing left to call it, the device identifier is used")

    // Malformed input is empty, not a crash.
    expect(
        "\(DriveScanner.drives(inList: [:], info: { _ in [:] }).count)", "0",
        "a plist without the expected key yields nothing")
    let noIdent: [String: Any] = [
        "AllDisksAndPartitions": [
            ["DeviceIdentifier": "diskA", "Partitions": [["Content": "Microsoft Basic Data"]]]
        ]
    ]
    expect(
        "\(DriveScanner.drives(inList: noIdent, info: { _ in [:] }).count)", "0",
        "a partition with no device identifier is skipped")
}

group("workspaceLifecycle") {
    let ws = try! Workspace()
    let fm = FileManager.default
    expect(fm.fileExists(atPath: ws.root.path), "a workspace is a directory that exists")

    // It holds a credential pipe. Anyone else being able to read it would be
    // the whole point of the FIFO gone.
    let attrs = try! fm.attributesOfItem(atPath: ws.root.path)
    expect(
        "\((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)", "448",
        "and is readable only by its owner (0700)")

    // Finder names a network mount after the last component of the path the
    // engine was handed, so the link's name is what the drive ends up called.
    let link = try! ws.makeDeviceAlias(named: "My Drive", target: "/dev/disk9s1")
    expect(link.lastPathComponent, "My Drive", "the alias is named after the drive")
    expect(
        try! fm.destinationOfSymbolicLink(atPath: link.path), "/dev/disk9s1",
        "and points at the device")

    // A slash would make a directory, a colon is how Finder writes one.
    let odd = try! ws.makeDeviceAlias(named: "a/b:c", target: "/dev/disk9s1")
    expect(odd.lastPathComponent, "a-b-c", "separators in a volume name are replaced")

    let blank = try! ws.makeDeviceAlias(named: "   ", target: "/dev/disk9s1")
    expect(blank.lastPathComponent, "Encrypted Drive", "a drive with no name still gets one")

    let long = try! ws.makeDeviceAlias(named: String(repeating: "x", count: 100), target: "/dev/x")
    expect("\(long.lastPathComponent.count)", "40", "and a very long one is cut to fit")

    // Made twice, because a retry after a failed unlock goes through here again.
    let again = try! ws.makeDeviceAlias(named: "My Drive", target: "/dev/disk9s2")
    expect(
        try! fm.destinationOfSymbolicLink(atPath: again.path), "/dev/disk9s2",
        "making the same alias twice replaces it rather than failing")

    // The credential is handed over through a FIFO so it never reaches a
    // command line, an exported environment, or a file on disk. A regular file
    // here would defeat all of that while still working.
    let fifo = try! ws.makeCredentialPipe()
    var st = stat()
    expect(stat(fifo.path, &st) == 0, "the credential pipe is created")
    expect((st.st_mode & S_IFMT) == S_IFIFO, "as a FIFO, not a file")
    expect("\(st.st_mode & 0o777)", "384", "readable only by its owner (0600)")

    let root = ws.root
    ws.destroy()
    expect(!fm.fileExists(atPath: root.path), "destroying it takes the whole directory")
    ws.destroy()
    expect(!fm.fileExists(atPath: root.path), "and destroying it twice is not an error")
}

group("engineUnpacking") {
    let fm = FileManager.default
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lukotta-unpack-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }

    // A stand-in for the bundled rootfs: what matters is that unpacking is
    // driven by whether "rootfs" ends up on disk, not by tar's exit status
    // alone. The real archive is 95 MB and is not unpacked by a test.
    let staging = temp.appendingPathComponent("staging", isDirectory: true)
    try! fm.createDirectory(
        at: staging.appendingPathComponent("rootfs/etc", isDirectory: true),
        withIntermediateDirectories: true)
    try! "hello".write(
        to: staging.appendingPathComponent("rootfs/etc/hostname"), atomically: true,
        encoding: .utf8)
    let archive = temp.appendingPathComponent("rootfs.tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", archive.path, "-C", staging.path, "rootfs"]
    try! tar.run()
    tar.waitUntilExit()

    let target = temp.appendingPathComponent("alpine", isDirectory: true)
    expect(!EngineEnvironment.isReady(in: target), "nothing is unpacked to begin with")

    var messages: [String] = []
    let worked = try! EngineEnvironment.prepare(into: target, from: archive) { messages.append($0) }
    expect(worked, "the first run does the work")
    expect(EngineEnvironment.isReady(in: target), "and leaves a rootfs behind")
    expect(
        (try? String(
            contentsOf: target.appendingPathComponent("rootfs/etc/hostname"), encoding: .utf8))
            == "hello", "with the contents intact")
    expect(!messages.isEmpty, "saying what it is doing, because it is the longest wait there is")

    let second = try! EngineEnvironment.prepare(into: target, from: archive) { _ in }
    expect(!second, "a second run does nothing and says so")

    // A file that is not an archive: tar fails, and the failure is reported
    // rather than leaving a half-unpacked directory looking ready.
    let broken = temp.appendingPathComponent("broken", isDirectory: true)
    let notAnArchive = temp.appendingPathComponent("not-a-tarball.tar.gz")
    try! "this is not gzip".write(to: notAnArchive, atomically: true, encoding: .utf8)
    var threw = false
    do { _ = try EngineEnvironment.prepare(into: broken, from: notAnArchive) { _ in } } catch {
        threw = true
        // The message carries what tar said, not an empty string where it
        // should have been.
        expect("\(error)".count > 40, "and says what went wrong")
    }
    expect(threw, "an archive that will not unpack is an error")
    expect(!EngineEnvironment.isReady(in: broken), "and nothing is left looking ready")
}

group("unpackingProgress") {
    expect(
        "\(EngineEnvironment.percentage(seen: 0, expected: 100) ?? -1)", "0", "starts at nothing")
    expect("\(EngineEnvironment.percentage(seen: 50, expected: 100) ?? -1)", "50", "and counts up")
    // The entry count is written at build time and can be short. A bar that
    // sits at 100 while the app is still working reads as a hang.
    expect(
        "\(EngineEnvironment.percentage(seen: 100, expected: 100) ?? -1)", "99",
        "but never reaches the end before the work does")
    expect(
        "\(EngineEnvironment.percentage(seen: 9999, expected: 100) ?? -1)", "99",
        "even when the count was badly wrong")
    expect(
        EngineEnvironment.percentage(seen: 10, expected: 0) == nil,
        "with nothing to count against, no percentage is claimed")
}

group("bootSectorIdentification") {
    // A first sector, built the way the real ones are: a jump instruction,
    // then eight bytes of OEM name.
    func sector(oem: String, identifierAt offset: Int? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: BootSector.length)
        bytes[0] = 0xEB
        bytes[1] = 0x58
        bytes[2] = 0x90
        for (i, byte) in Array(oem.utf8).enumerated() where i < 8 { bytes[3 + i] = byte }
        if let offset {
            for (i, byte) in BootSector.bitlockerIdentifier.enumerated() {
                bytes[offset + i] = byte
            }
        }
        return Data(bytes)
    }

    expect(
        "\(BootSector.identify(sector(oem: "-FVE-FS-")))", "bitlocker",
        "a BitLocker volume names itself in the header")
    expect(
        "\(BootSector.identify(sector(oem: "NTFS    ")))", "ntfs",
        "and so does plain NTFS, which is the one people were finding out about by failing")
    expect("\(BootSector.identify(sector(oem: "EXFAT   ")))", "exfat", "exFAT too")

    // BitLocker To Go writes a FAT-looking header. Reading only the name would
    // call an encrypted drive unencrypted, which is the worst answer available.
    expect(
        "\(BootSector.identify(sector(oem: "MSWIN4.1", identifierAt: 0x70)))", "bitlocker",
        "a drive that looks like FAT is still BitLocker when it carries the identifier")
    expect(
        "\(BootSector.identify(sector(oem: "MSWIN4.1")))", "unknown",
        "and without the identifier no claim is made about it")

    // The identifier is authoritative wherever it sits in the sector.
    expect(
        "\(BootSector.identify(sector(oem: "NTFS    ", identifierAt: 0x1F0)))", "bitlocker",
        "the identifier outranks the name, wherever in the sector it is")

    // Nothing recognised is nothing said. A wrong guess here sends someone
    // looking for a password that does not exist.
    // A container file made with cryptsetup has no partition table at all, so
    // this is the only thing that says what it is.
    var luks = [UInt8](repeating: 0, count: BootSector.length)
    for (i, b) in BootSector.luksMagic.enumerated() { luks[i] = b }
    expect("\(BootSector.identify(Data(luks)))", "luks", "a LUKS container names itself first")

    // Only at the start. Six bytes turn up by chance often enough that finding
    // them anywhere would call other things LUKS.
    var misplaced = [UInt8](repeating: 0, count: BootSector.length)
    for (i, b) in BootSector.luksMagic.enumerated() { misplaced[64 + i] = b }
    for (i, b) in Array("NTFS    ".utf8).enumerated() { misplaced[3 + i] = b }
    expect(
        "\(BootSector.identify(Data(misplaced)))", "ntfs",
        "and those bytes elsewhere in the sector mean nothing")

    expect(
        "\(BootSector.identify(sector(oem: "XXXXXXXX")))", "unknown", "an unknown header is unknown"
    )
    expect("\(BootSector.identify(Data()))", "unknown", "an empty read is not an answer")
    expect("\(BootSector.identify(Data([0xEB, 0x58])))", "unknown", "and neither is a short one")

    // Data slices do not start at zero. Reading the name from the wrong end of
    // one would misidentify every drive.
    let padded = Data([0, 0, 0, 0]) + sector(oem: "NTFS    ")
    expect(
        "\(BootSector.identify(padded.dropFirst(4)))", "ntfs",
        "a sector read into the middle of a buffer reads the same")
}

group("diagnosisRulesAreTiedToAnEngineVersion") {
    // The whole of this matches on text, because the engine exits 0 whether or
    // not the mount worked and there is nothing else to match on. What must not
    // happen is an upgrade rewording a phrase and every rule quietly ceasing to
    // fire, with people shown raw output for a release or two before anyone
    // notices.
    let lock =
        (try? String(contentsOfFile: "vendor/engine.lock", encoding: .utf8))
        ?? (try? String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/vendor/engine.lock",
            encoding: .utf8))
    if let lock,
        let data = lock.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let engine = root["anylinuxfs"] as? [String: Any],
        let version = engine["version"] as? String
    {
        expect(
            Diagnosis.enginesChecked.contains(version),
            "the rules have been checked against engine \(version) — if this fails, read the "
                + "release notes, try the failure paths, then add it to Diagnosis.enginesChecked")
    } else {
        // Not a silent pass: a test that cannot find what it checks is a test
        // that is not running.
        expect(false, "vendor/engine.lock could be read")
    }

    // Every rule says where its words come from, because that is what says how
    // likely they are to change, and no rule is empty.
    for rule in Diagnosis.rules {
        expect(!rule.patterns.isEmpty, "\(rule.name) looks for something")
        expect(!rule.message().isEmpty, "\(rule.name) says something")
        expect(
            rule.patterns.allSatisfy { $0 == $0.lowercased() },
            "\(rule.name) is matched against lowercased output, so its patterns are lowercase")
    }

    // Order matters: the first match wins. "No key available" is a refused
    // password, and the filesystem rule below it would otherwise claim the
    // volume was unreadable.
    expect(
        Diagnosis.rule(for: "cryptsetup: No key available with this passphrase.")?.name
            ?? "none", "wrong-credential", "a refused key is a refused key")
    expect(
        Diagnosis.rule(for: "mount: unknown filesystem type 'crypto_LUKS'")?.name ?? "none",
        "unrecognised-filesystem", "and an unreadable volume is that")

    // Real lines, from the tools that actually emit them.
    let known: [(String, String)] = [
        ("anylinuxfs: cannot probe /dev/disk4s1: insufficient permissions", "no-full-disk-access"),
        ("device-mapper: reload ioctl failed: Wrong key", "wrong-credential"),
        ("bdemount: unable to open BitLocker volume: no BitLocker signature", "not-bitlocker"),
        ("ntfs3: volume is dirty and \"force\" flag is not set", "windows-hibernated"),
        ("mount: /mnt: no such device", "unrecognised-filesystem"),
        ("blkid: TYPE=\"LVM2_member\"", "container-not-understood"),
        ("Error: another instance is already running", "engine-lock-held"),
        ("diskutil: volume is already mounted at /Volumes/BACKUP", "already-mounted"),
        ("hv_vm_create failed", "hypervisor-refused"),
        ("umount: /Volumes/X: device busy", "busy"),
    ]
    for (line, expected) in known {
        expect(Diagnosis.rule(for: line)?.name ?? "none", expected, "\(expected) recognised")
    }

    // Output nobody has a rule for falls through to the engine's own words
    // rather than to a shrug.
    expect(
        Diagnosis.rule(for: "something entirely new went wrong") == nil,
        "an unrecognised failure matches nothing")
    expect(
        Diagnosis.summarise("modprobe: FATAL: could not insert module", fallback: ""),
        "modprobe: FATAL: could not insert module",
        "and the engine's own line is shown instead")
}

group("ejectingIsOneAtATime") {
    // A drive takes seconds to eject and the engine is told to wait thirty for
    // the virtual machine. Anything past that is the engine not returning, not
    // the machine being slow, and the interface needs an answer rather than a
    // spinner that never stops.
    expect(
        EngineStatus.unmountTimeout > 30,
        "the deadline leaves room for the wait the engine is told to make")

    // Nothing to unmount, and a deadline far too short to reach the engine:
    // the answer is a refusal, not a hang.
    let started = Date()
    let result = EngineStatus.unmount(mountPoint: "/Volumes/nothing-here", timeout: 0.2)
    expect(!result.ok, "an eject that does not finish in time is not a success")
    expect(
        Date().timeIntervalSince(started) < 5,
        "and it comes back at once rather than waiting for the engine")
}

group("wholeDiskOfAPartition") {
    expect(DriveScanner.wholeDisk(of: "disk6s1"), "disk6", "a partition belongs to its disk")
    expect(DriveScanner.wholeDisk(of: "disk12s3"), "disk12", "two-digit disks too")
    expect(DriveScanner.wholeDisk(of: "disk6"), "disk6", "a whole disk is its own")
    // The "disk" prefix has an s in it. Cutting at the first one would make
    // every disk in the list belong to "di".
    expect(DriveScanner.wholeDisk(of: "disk6s1s2"), "disk6", "and a nested one still belongs to it")
}

group("openingAContainerFile") {
    // The real thing, end to end: a file with a LUKS header, attached by
    // macOS, recognised, and put back. No engine, no root — an attached image
    // belongs to whoever attached it.
    let fm = FileManager.default
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lukotta-image-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }

    // Eight megabytes of nothing with a LUKS header on the front, which is
    // what cryptsetup leaves at the start of a container.
    let file = temp.appendingPathComponent("container.img")
    var bytes = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
    for (i, b) in BootSector.luksMagic.enumerated() { bytes[i] = b }
    try! Data(bytes).write(to: file)

    switch DiskImage.attach(file) {
    case .failure:
        expect(false, "a raw container file attaches")
    case .success(let attached):
        expect(attached.device.hasPrefix("/dev/disk"), "and comes back as a device")
        expect(attached.identifier.hasPrefix("disk"), "named the way diskutil names it")

        // No partition table, so the ordinary scan finds nothing here. This is
        // the case that would otherwise look like an unopenable file.
        let listed = DriveScanner.scan(images: [attached.identifier])
            .filter { DriveScanner.wholeDisk(of: $0.id) == attached.identifier }
        expect(listed.isEmpty, "a container with no partition table lists nothing on its own")

        let drive = DiskImage.wholeDiskDrive(attached, url: file)
        expect(drive != nil, "but the whole disk is recognised from its first sector")
        expect("\(drive?.kind ?? .microsoft)", "linux", "as a Linux container")
        expect(drive?.name ?? "", "container", "named after the file, without the extension")
        expect(
            drive?.uuid ?? "", file.path,
            "and identified by the file, so a saved passphrase survives reattaching")

        expect(DiskImage.detach(attached.device), "and it detaches again")
    }

    // A file that is not an image at all still attaches: a raw image is just
    // bytes, so macOS will treat anything as one. Attaching is therefore not
    // the test of whether a file is openable — what is in it is, and a text
    // file holds nothing, so it is recognised as nothing and put back.
    let text = temp.appendingPathComponent("notes.txt")
    try! String(repeating: "not a disk image\n", count: 512)
        .write(to: text, atomically: true, encoding: .utf8)
    switch DiskImage.attach(text) {
    case .failure:
        expect(true, "a file with nothing in it is refused, one way or the other")
    case .success(let attached):
        expect(
            DiskImage.wholeDiskDrive(attached, url: text) == nil,
            "a file that holds no container is not offered as a drive")
        DiskImage.detach(attached.device)
    }
}

group("aContainerFileStaysInTheList") {
    // The bug this covers: a container with no partition table is a row the
    // scan cannot produce, because diskutil reports the disk as empty. It was
    // added once when the file was opened, and the next refresh — a drive
    // being plugged in, a mount finishing, anything — rebuilt the list without
    // it. The app then decided the drive had vanished and announced it as
    // disconnected, while the mount it was serving carried on working.
    let image = Drive(
        id: "disk7", devicePath: "/dev/disk7", name: "backup", sizeBytes: 320,
        connection: "Disk Image", kind: .linux, uuid: "/Users/someone/backup.img")
    let physical = Drive(
        id: "disk4s1", devicePath: "/dev/disk4s1", name: "Elements", sizeBytes: 500,
        connection: "USB", kind: .microsoft, uuid: "UUID-1")

    // A scan that knows nothing about the container still ends up listing it.
    let merged = ImageList.merge(found: [physical], images: ["disk7": image])
    expect("\(merged.count)", "2", "the container is put back into a scan without it")
    expect(merged.contains { $0.id == "disk7" }, "and it is the one that was opened")

    // Once the scan can see it — a container that does have a partition table,
    // or the same disk reappearing — it is not added twice.
    let partition = Drive(
        id: "disk7s1", devicePath: "/dev/disk7s1", name: "backup", sizeBytes: 320,
        connection: "Disk Image", kind: .linux, uuid: "UUID-2")
    let once = ImageList.merge(found: [partition], images: ["disk7": image])
    expect("\(once.count)", "1", "a container the scan can see is not listed twice")

    // Ejecting is what takes it out, and only the one that was ejected.
    let ejected = ImageList.detaching(
        devices: ["/dev/disk7"], images: ["disk7": image, "disk9": physical])
    expect(ejected.joined(separator: ","), "disk7", "ejecting a container detaches that container")
    let untouched = ImageList.detaching(
        devices: ["/dev/disk4s1"], images: ["disk7": image])
    expect(untouched.isEmpty, "and ejecting something else leaves it alone")
}

group("unencryptedFilesystemsNeedNoPassword") {
    // A container or a drive holding an ordinary filesystem has nothing to
    // unlock, and asking for a passphrase for one is asking for something that
    // does not exist. Each writes its magic at one place and only there.
    func image(_ bytes: [(Int, [UInt8])]) -> Data {
        var buffer = [UInt8](repeating: 0, count: BootSector.length)
        for (offset, magic) in bytes {
            for (i, b) in magic.enumerated() where offset + i < buffer.count {
                buffer[offset + i] = b
            }
        }
        return Data(buffer)
    }

    // ext puts its superblock at 1024 and its magic 56 bytes into it.
    expect("\(BootSector.identify(image([(1080, [0x53, 0xEF])])))", "ext", "ext is recognised")
    // btrfs writes its signature 64 KB in, which is why a single sector was
    // never going to be enough.
    expect(
        "\(BootSector.identify(image([(65600, Array("_BHRfS_M".utf8))])))", "btrfs",
        "btrfs is recognised, well past the first sector")
    expect(
        "\(BootSector.identify(image([(0, Array("XFSB".utf8))])))", "xfs", "and XFS at the front")

    // Not at that offset is not that filesystem.
    expect(
        "\(BootSector.identify(image([(2048, [0x53, 0xEF])])))", "unknown",
        "ext's two bytes elsewhere mean nothing")
    expect(
        "\(BootSector.identify(image([(1024, Array("_BHRfS_M".utf8))])))", "unknown",
        "and so does btrfs's signature in the wrong place")

    // Encryption wins wherever it appears, because getting this backwards
    // would tell someone their encrypted drive needs no password.
    expect(
        "\(BootSector.identify(image([(0, BootSector.luksMagic), (1080, [0x53, 0xEF])])))",
        "luks", "a LUKS container holding ext is still a LUKS container")

    // Which of them open without being asked for anything.
    for format in [VolumeFormat.ntfs, .exfat, .ext, .btrfs, .xfs] {
        expect(format.isUnencrypted, "\(format) opens without a password")
    }
    for format in [VolumeFormat.bitlocker, .luks, .unknown] {
        expect(!format.isUnencrypted, "\(format) does not")
    }
}

group("whatMacOSDoesBetterOnItsOwn") {
    // The app is worth reaching for only where macOS cannot manage. exFAT it
    // mounts locally, read and write; opening one here would turn a local
    // volume into a network one for nothing.
    expect(VolumeFormat.exfat.macOSHandlesFully, "exFAT is left to macOS")

    // NTFS is not on that list, and the distinction is the point: macOS mounts
    // it read-only, and writing to it is the whole reason to open it here.
    expect(!VolumeFormat.ntfs.macOSHandlesFully, "NTFS is not, because macOS only reads it")
    for format in [VolumeFormat.ext, .btrfs, .xfs] {
        expect(!format.macOSHandlesFully, "\(format) is not, because macOS cannot read it at all")
    }
    for format in [VolumeFormat.luks, .bitlocker] {
        expect(!format.macOSHandlesFully, "\(format) is not, because it is encrypted")
    }

    // Everything macOS handles fully is by definition unencrypted, and the two
    // together are what decide whether a drive opens on its own.
    for format in [VolumeFormat.bitlocker, .luks, .ntfs, .exfat, .ext, .btrfs, .xfs, .unknown] {
        if format.macOSHandlesFully {
            expect(format.isUnencrypted, "\(format) is handled by macOS and so has no password")
        }
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("PASS: LukottaCore")
