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

    //
    // This text becomes a command run as root. Both production-breaking bugs so far
    // were malformed arguments here, and neither was reachable by a test while
    // generation and execution lived in the same function.

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
        !msScript.contains("LUKOTTA_MULTIPLE_VOLUMES"),
        "no LVM discovery for a Microsoft volume")

    // The alias was meant to give Finder a friendlier name by being mounted in
    // place of the device. It never could: the engine prefixes /dev/ onto the
    // target it is handed, so an alias under /tmp resolved to /dev//tmp/… and
    // every mount opened with a "disk not found" line. Names come from
    // DriveMemory instead, and an alias outside /dev is no longer attempted.
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
    expect(!msChosen.contains("LUKOTTA_MULTIPLE_VOLUMES"), "no rediscovery once chosen")
    expect(!msChosen.contains("-t ntfs"), "no driver override for a chosen volume")

    // Paths with spaces must survive quoting: they reach a root shell. The
    // workspace sits under a temporary directory the user does not choose, so
    // this is not hypothetical.
    let msSpaces = MountScript.build(
        MountScript.Inputs(
            enginePath: "/eng/any linux fs", devicePath: "/dev/disk4s1", driveName: "D",
            kind: .linux, volume: nil, aliasPath: nil, fifoPath: "/tmp/My Space/fifo",
            logPath: "/tmp/My Space/mount.log", discoverLogPath: "/tmp/My Space/discover.log",
            expectScriptPath: "/tmp/My Space/discover.exp", libraryPaths: ["/eng/li b"],
            uid: 501, gid: 20, cores: 4, ramMiB: 2560))
    expect(msSpaces.contains("'/tmp/My Space/mount.log'"), "spaces in paths stay quoted")
    expect(msSpaces.contains("'/eng/any linux fs'"), "spaces in the engine path stay quoted")
    expect(msSpaces.contains("'/tmp/My Space/discover.exp'"), "spaces in the expect path quoted")
}

group("mountStages") {
    // The engine exits 0 on a failed mount: the status is its own shutdown, not
    // the mount's. Every fallback is chained with ||, so a mount attempt has to
    // be judged by whether a mount appeared, not by what the engine returned.
    // Without this the first attempt always looked like a success and nothing
    // after it ever ran — no ntfs-3g retry, no LVM discovery.
    let checked = MountScript.build(sampleInputs(kind: .linux))
    expect(checked.contains("__mounts=$(/sbin/mount | grep -c ':/mnt/')"), "a baseline is taken")
    expect(
        checked.contains(
            """
            2>&1 && [ "$(/sbin/mount | grep -c ':/mnt/')" -gt "$__mounts" ]
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
            libraryPaths: [], uid: 501, gid: 20, cores: 4, ramMiB: 2560))
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

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("PASS: LukottaCore")
