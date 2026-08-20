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

    // The friendly alias is tried before the real device, so Finder shows a name.
    expect(
        msScript.range(of: "alias/Elements")!.lowerBound
            < msScript.range(of: "'/dev/disk4s1'")!.lowerBound,
        "alias attempted before the raw device")
    // …but the device is always attempted too, so a symlink cannot break mounting.
    expect(msScript.contains("'/dev/disk4s1'"), "raw device always attempted as fallback")

    let msNoAlias = MountScript.build(sampleInputs(alias: nil))
    expect(msNoAlias.contains("'/dev/disk4s1'"), "device used when no alias is available")

    // Linux volumes: no driver override, and LVM discovery appended.
    let msLinux = MountScript.build(sampleInputs(kind: .linux))
    expect(!msLinux.contains("-t ntfs"), "no NTFS driver forced on a Linux volume")
    expect(msLinux.contains("LUKOTTA_MULTIPLE_VOLUMES"), "LVM discovery present for Linux")
    expect(msLinux.contains("expect -f '/tmp/ws/discover.exp'"), "discovery driven through expect")
    expect(msLinux.contains("lvm:$__lvs"), "a single logical volume is mounted directly")

    // A volume the user picked is mounted directly, with no discovery or override.
    let lv = LogicalVolume(
        identifier: "ubuntuvg:disk4s1:home", label: "HOMEFS",
        filesystem: "btrfs", size: "394 MB")
    let msChosen = MountScript.build(sampleInputs(kind: .linux, volume: lv))
    expect(msChosen.contains("'lvm:ubuntuvg:disk4s1:home'"), "chosen volume mounted by identifier")
    expect(!msChosen.contains("LUKOTTA_MULTIPLE_VOLUMES"), "no rediscovery once chosen")
    expect(!msChosen.contains("-t ntfs"), "no driver override for a chosen volume")

    // Paths with spaces must survive quoting: they reach a root shell.
    let msSpaces = MountScript.build(sampleInputs(alias: "/tmp/ws/alias/My Backup Drive"))
    expect(msSpaces.contains("'/tmp/ws/alias/My Backup Drive'"), "spaces in paths stay quoted")
}

group("mountStages") {

    expect(MountStage.inferred(from: []) == .preparing, "no output yet means preparing")
    expect(
        MountStage.inferred(from: ["Waiting for your administrator approval…"]) == .authorising,
        "approval line detected")
    expect(MountStage.inferred(from: ["booting linux kernel"]) == .starting, "vm start detected")
    expect(
        MountStage.inferred(from: ["Enter passphrase for /dev/disk4s1"]) == .unlocking,
        "unlock detected")
    expect(MountStage.inferred(from: ["starting nfs export"]) == .sharing, "sharing detected")
    // Stages only ever move forward, because matching on text is loose.
    expect(
        MountStage.inferred(from: ["starting nfs export", "booting linux"]) == .sharing,
        "stage never goes backwards")

    expect(Permissions.isAccessDenied("Cannot probe /dev/disk4s1"), "access denial detected")
    expect(!Permissions.isAccessDenied("No key available"), "wrong key is not an access denial")
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
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("PASS: LukottaCore")
