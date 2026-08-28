// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import LukottaCore

// A plain executable rather than XCTest or swift-testing. Neither ships with
// the Command Line Tools, and requiring a full Xcode install to run the tests
// would put them out of reach of anyone building from source, and of CI.
var failures = 0, checks = 0, currentGroup = ""

// A way to read the script a mount actually runs, for when it stops working
// and no amount of reading the generator says why.
if ProcessInfo.processInfo.environment["LUKOTTA_DUMP_MOUNT_SCRIPT"] != nil {
    print(
        MountScript.build(
            MountScript.Inputs(
                enginePath: "/opt/engine/anylinuxfs", devicePath: "/dev/disk4s1",
                driveName: "BACKUP", kind: .linux, aliasPath: nil,
                fifoPath: "/tmp/w/credential.fifo", logPath: "/tmp/w/mount.log",
                discoverLogPath: "/tmp/w/discover.log", expectScriptPath: "/tmp/w/discover.exp",
                configPath: "/tmp/h/config.toml", engineHome: "/tmp/h", libraryPaths: ["/tmp/lib"],
                uid: 501, gid: 20, cores: 2, ramMiB: 1024, elevated: false, readOnly: false)))
    exit(0)
}

// Top-level code is on the main actor, so the state these keep is too.
@MainActor
func group(_ name: String, _ body: @MainActor () -> Void) {
    // Nested, the inner group takes over currentGroup and never gives it back,
    // so a later failure in the outer one is reported under the inner name and
    // the outer verdict silently includes the inner group's result. Refused
    // outright rather than handled: two topics in one group is the mistake, and
    // a stack would make it comfortable.
    if !currentGroup.isEmpty {
        print("    FAIL [\(currentGroup)] the group \"\(name)\" is nested inside it")
        failures += 1
    }
    currentGroup = name
    let before = failures
    body()
    print("  \(failures == before ? "ok  " : "FAIL") \(name)")
    currentGroup = ""
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
    alias: String? = "/tmp/ws/alias/Elements",
    readOnly: Bool = false
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
        configPath: "/Users/u/Library/Application Support/Lukotta/engine/.anylinuxfs/config.toml",
        engineHome: "/Users/u/Library/Application Support/Lukotta/engine",
        libraryPaths: ["/engine/lib"],
        uid: 501, gid: 20, cores: 4, ramMiB: 2560, readOnly: readOnly)
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

group("whatWasAttachedIsPutBack") {
    // Attaching is this app's business. A container left attached after a quit
    // comes back next time as a disk with no name and no explanation, which is
    // how two turned up in somebody's list days later.
    let opened = [
        "disk5": URL(fileURLWithPath: "/Users/someone/Desktop/one.img"),
        "disk6": URL(fileURLWithPath: "/Users/someone/Desktop/two.img"),
    ]
    expect(
        ImageList.detachingOnQuit(opened: opened, mountedDevices: []) == ["disk5", "disk6"],
        "with nothing open, everything attached is put back")
    // Quitting with a drive left open keeps the device that serves it.
    expect(
        ImageList.detachingOnQuit(opened: opened, mountedDevices: ["/dev/disk5s1"]) == ["disk6"],
        "except the one still serving a mount somebody asked to keep")
    expect(
        ImageList.detachingOnQuit(opened: [:], mountedDevices: []).isEmpty,
        "and nothing at all when nothing was attached")
}

group("aDiskWithNoPartitionTableIsStillADrive") {
    // cryptsetup luksFormat /dev/sdb makes one, and so does dd. There is no
    // partition to describe it and diskutil says nothing about what is inside,
    // so the disk itself is the volume. Skipping these hid exactly the drives
    // somebody would reach for this app to open.
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk7", "Size": NSNumber(value: 64_000_000_000)],
            // A disk with a table is described by the table, as before.
            [
                "DeviceIdentifier": "disk8",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk8s1", "Content": "Microsoft Basic Data",
                        "Size": NSNumber(value: 500_000_000_000),
                    ]
                ],
            ],
            // The system's own container is not offered whole.
            [
                "DeviceIdentifier": "disk3",
                "APFSVolumes": [
                    [
                        "DeviceIdentifier": "disk3s1", "Content": "Apple_APFS",
                        "VolumeName": "Macintosh HD",
                        "Size": NSNumber(value: 16_000_000_000),
                    ]
                ],
            ],
        ]
    ]
    let found = DriveScanner.drives(inList: plist, info: { _ in [:] })
    let ids = found.map(\.id)
    expect(ids.contains("disk7"), "a disk with no partition table is offered whole")
    expect(ids.contains("disk8s1"), "and a partitioned one is still offered by partition")
    expect(!ids.contains("disk8"), "but not twice")
    expect(!ids.contains("disk3"), "an APFS container is not a drive to open")
    expect(found.first { $0.id == "disk7" }?.devicePath == "/dev/disk7", "the device is the disk")

    // An internal disk with no table is the Mac's own and is left alone.
    let internalOnly: [String: Any] = [
        "AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk9", "Size": NSNumber(value: 500_000_000_000)]
        ]
    ]
    let none = DriveScanner.drives(
        inList: internalOnly, info: { _ in ["Internal": true] })
    expect(none.isEmpty, "an internal disk with no table is not offered")
}

group("theSurveyAgreesWithTheScannerAndHidesTheSystem") {
    // The survey judged a partition by its own two sets of names and the
    // scanner judged it by VolumeKind.holding. An MBR BitLocker drive was
    // therefore listed as "not a format Lukotta can open" while the scanner
    // would have opened it.
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4", "Content": "FDisk_partition_scheme",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk4s1", "Content": "Windows_NTFS",
                        "Size": NSNumber(value: 247_630_659_584),
                    ]
                ],
            ],
            [
                "DeviceIdentifier": "disk3", "Content": "Apple_APFS_Container",
                "APFSVolumes": [
                    [
                        "DeviceIdentifier": "disk3s1", "Content": "Apple_APFS",
                        "VolumeName": "Macintosh HD",
                        "Size": NSNumber(value: 16_000_000_000),
                    ],
                    [
                        "DeviceIdentifier": "disk3s2", "Content": "Apple_APFS",
                        "VolumeName": "Preboot",
                        "Size": NSNumber(value: 18_000_000_000),
                    ],
                    [
                        "DeviceIdentifier": "disk3s6", "Content": "Apple_APFS", "VolumeName": "VM",
                        "Size": NSNumber(value: 34_000_000_000),
                    ],
                ],
            ],
        ]
    ]
    let rows = DriveSurvey.survey(
        list: plist, info: { _ in [:] }, mountTable: "", openable: [])
    let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

    expect(
        by["disk4s1"]?.verdict == .openable,
        "an MBR BitLocker drive is offered, not written off")
    expect(by["disk3s2"]?.verdict == .system, "Preboot belongs to the system")
    expect(by["disk3s6"]?.verdict == .system, "and so does VM")
    expect(
        rows.filter { $0.verdict == .system }.count == 2,
        "APFS's own volumes are the ones folded away, and only those")
}

group("aPartitionIsRecognisedWhicheverSchemeWroteIt") {
    // A GPT disk names the type by its GUID's readable name; an MBR disk gives
    // the old DOS name. Windows still writes MBR on a USB stick, and BitLocker
    // To Go leaves one behind, so reading only the GPT names hid exactly the
    // drives this app exists to open.
    expect(VolumeKind.holding("Microsoft Basic Data") == .microsoft, "GPT: Microsoft Basic Data")
    expect(VolumeKind.holding("Windows_NTFS") == .microsoft, "MBR: Windows_NTFS")
    expect(VolumeKind.holding("Linux Filesystem") == .linux, "GPT: Linux Filesystem")
    expect(VolumeKind.holding("Linux") == .linux, "MBR: Linux")
    expect(VolumeKind.holding("Linux_LVM") == .linux, "LVM, either scheme")
    expect(VolumeKind.holding("Linux_RAID") == .linux, "RAID, either scheme")
    // Not ours: macOS reads these itself, and offering them would invite
    // somebody to open their own system disk.
    expect(VolumeKind.holding("Apple_APFS") == nil, "APFS is macOS's own")
    expect(VolumeKind.holding("Windows_FAT_32") == nil, "plain FAT is read by macOS")
    expect(VolumeKind.holding("EFI") == nil, "the EFI partition is nobody's business")
    expect(VolumeKind.holding("") == nil, "a disk with no partition table at all")
}

group("volumeKindsAndTheDirtyVolumePath") {

    // What may be there, until a probe says which of them it is.
    expect(VolumeKind.microsoft.summary, "BitLocker/NTFS", "microsoft kind summary")
    expect(VolumeKind.linux.summary, "LUKS/Linux", "linux kind summary")
    // And once it has, one name rather than a pair.
    expect(VolumeKind.microsoft.summary(knowing: .ntfs), "NTFS", "a probed microsoft volume")
    expect(
        VolumeKind.microsoft.summary(knowing: .bitlocker), "BitLocker", "a probed BitLocker volume")
    expect(VolumeKind.linux.summary(knowing: .ext), "ext", "a probed Linux filesystem")
    expect(VolumeKind.linux.summary(knowing: .luks), "LUKS", "a probed LUKS container")
    expect(
        VolumeKind.linux.summary(knowing: .unknown), "LUKS/Linux",
        "an unrecognised probe leaves the pair standing")
    // And once it is open, both halves: the lock and what was behind it.
    expect(
        VolumeKind.linux.summary(knowing: .luks, holding: "Btrfs"), "LUKS/Btrfs",
        "an opened container names what it held")
    expect(
        VolumeKind.microsoft.summary(knowing: .bitlocker, holding: "NTFS"), "BitLocker/NTFS",
        "and so does an opened BitLocker volume")
    expect(
        VolumeKind.microsoft.summary(knowing: .ntfs, holding: "NTFS"), "NTFS",
        "a drive that was never locked is named once, not twice")
    expect(
        VolumeFormat.filesystemName(fromDriver: "ntfs3"), "NTFS",
        "the driver the engine used is not what the filesystem is called")
    expect(
        VolumeFormat.filesystemName(fromDriver: "ext4"), "ext4",
        "and one with no other name keeps the engine's")

    // diskutil answers with an empty string as readily as it omits a key, and
    // a whole disk with no partition table is where it does.
    let bare = DriveSurvey.survey(
        list: [
            "AllDisksAndPartitions": [
                ["DeviceIdentifier": "disk9", "Content": "", "Size": NSNumber(value: 1024)]
            ]
        ],
        info: { _ in [:] }, mountTable: "", openable: [])
    expect(bare.count == 1, "a disk with no partition table is still a row")
    expect(bare.first.map { !$0.name.isEmpty } ?? false, "and it is named")
    // Nothing is said about what it holds, because nothing here knows: the
    // partition scheme is not a thing on the disk, and the row already carries
    // the device name.
    expect(bare.first?.content == "", "and says nothing it cannot know")

    // diskutil's own words, in the vocabulary the drive list uses.
    expect(DriveSurvey.described("Windows_NTFS"), "BitLocker/NTFS", "a Microsoft partition type")
    expect(DriveSurvey.described("Linux_LVM"), "LUKS/Linux", "and a Linux one")
    expect(DriveSurvey.described("Apple_APFS_ISC"), "APFS", "APFS, whichever of its roles")
    expect(DriveSurvey.described("Apple_HFS"), "Mac OS Extended", "the old Mac filesystem")
    expect(DriveSurvey.described("GUID_partition_scheme"), "", "a partition scheme is not contents")
    expect(DriveSurvey.described("Some_New_Type"), "Some_New_Type", "and anything else stands")

    let d = Drive(
        id: "disk4s1", devicePath: "/dev/disk4s1", name: "BACKUP",
        sizeBytes: 500_000_000_000, connection: "USB · External", kind: .microsoft,
        uuid: "7A2E4F10-3C58-4D9B-A6E1-2F7C05B34D88")
    expect(d.subtitle.contains("BitLocker/NTFS"), "subtitle states what the volume might be")
    expect(d.subtitle.contains("disk4s1"), "subtitle keeps the device identifier")

    // Windows Fast Startup and hibernation are the most common cause of failure,
    // and the message must say what to do rather than repeat a driver error.
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

    // This text becomes a command run as root, and the failures it invites are
    // malformed arguments, none of which a test can reach while generation and
    // execution live in the same function.

    let msScript = MountScript.build(sampleInputs())

    // The regression that shipped for part of a day: driver options and
    // read-only each emitted their own -o, and the engine takes exactly one.
    // clap answers "the argument '--options <OPTIONS>' cannot be used multiple
    // times" and exits before touching the disk, so every read-only ntfs-3g
    // mount failed on a usage error -- the last resort for a hibernated drive,
    // and the whole path for anyone who opens NTFS read-only on purpose.
    //
    // Checked on the generated text rather than on the helper, because the
    // helper was correct in isolation both times and the fault was in what the
    // caller did with two correct answers.
    // Per invocation, not per line: one line of the script holds the whole
    // fallback chain, and each attempt in it gets its own -o.
    for (label, inputs) in [
        ("read-write NTFS", sampleInputs(kind: .microsoft)),
        ("read-only NTFS", sampleInputs(kind: .microsoft, readOnly: true)),
        ("read-only Linux", sampleInputs(kind: .linux, readOnly: true)),
    ] {
        let script = MountScript.build(inputs)
        var invocations = 0
        for chunk in script.components(separatedBy: "anylinuxfs' mount").dropFirst() {
            // A command ends where its output is redirected to the log.
            let command = chunk.components(separatedBy: ">>").first ?? chunk
            let flags = command.components(separatedBy: " -o ").count - 1
            invocations += 1
            expect(
                flags <= 1,
                "\(label): a mount command carries \(flags) -o flags, and the engine takes one")
        }
        expect(invocations > 0, "\(label): the script must contain a mount command to check")
    }

    // And the options that must survive being joined.
    expect(
        MountScript.mountOptions(driver: "ntfs-3g", readOnly: true) == " -o big_writes,ro",
        "ntfs-3g read-only joins big_writes and ro into one -o")
    expect(
        MountScript.mountOptions(driver: "ntfs-3g", readOnly: false) == " -o big_writes",
        "ntfs-3g read-write carries big_writes alone")
    expect(
        MountScript.mountOptions(driver: "ntfs3", readOnly: true) == " -o ro",
        "ntfs3 is given no driver options, so read-only stands alone")
    expect(
        MountScript.mountOptions(driver: nil, readOnly: false) == "",
        "a mount with nothing to say emits no -o at all")

    // The regression that broke v1.1.0: --nfs-options is variadic, so the separated
    // form consumes the device path and the engine reports "mount with no disk".
    expect(!msScript.contains("-n '"), "NFS options must never use the separated form")
    expect(
        msScript.contains(
            "--nfs-options='rsize=1048576,wsize=1048576,readahead=128,deadtimeout=300'"),
        "NFS options use the joined form")
    // Raising timeo was tried and taken out: the measurement behind it did not
    // reproduce, and deadtimeout=45 dominates anything above it anyway.
    expect(!msScript.contains("timeo="), "the timeout is left to the engine")
    // The measured fix: at the engine's deadtimeout=45 the same load unmounted
    // the drive by 90 seconds and the engine shut the microVM down with it; at
    // 300 the mount lived through ten minutes and recovered.
    expect(
        msScript.contains("deadtimeout=300"),
        "a slow drive gets five minutes, not forty-five seconds")
    expect(
        msScript.contains("'/dev/disk4s1' >>"),
        "the device is a positional argument, not swallowed by a preceding flag")

    // Stage 0: the microVM's NFS server is reached over vmnet rather than
    // gvproxy, which measured 2.5 times the write throughput on this machine.
    // Opening a vmnet interface without root arrived in macOS 26; below that
    // the engine refuses the helper outright rather than falling back, so a
    // build that asked for it everywhere would break every mount on macOS 15.
    expect(
        MountScript.netHelper(forMajorVersion: 26) == "vmnet",
        "macOS 26 opens vmnet without root, so it gets the faster network")
    expect(
        MountScript.netHelper(forMajorVersion: 27) == "vmnet",
        "anything above 26 keeps vmnet")
    expect(
        MountScript.netHelper(forMajorVersion: 15) == "gvproxy",
        "macOS 15 cannot open vmnet unprivileged, so it keeps gvproxy")
    expect(
        MountScript.netHelper(forMajorVersion: 25) == "gvproxy",
        "the boundary is 26, not 'recent'")
    // Every command that starts a microVM carries the choice: a mount that
    // asked for one network while a sibling asked for the other would leave
    // two helpers running and the second unable to reach its own guest.
    let engineMounts = msScript.split(separator: "\n").filter {
        $0.contains("ALFS_PASSPHRASE=") && $0.contains(" mount")
    }
    expect(!engineMounts.isEmpty, "the script does invoke the engine to mount")
    for line in engineMounts {
        expect(
            line.contains("--net-helper "),
            "every engine mount names the network helper: \(line.prefix(60))")
    }

    // The credential is read from the pipe, never written into the script --
    // and read byte for byte. Command substitution strips trailing newlines, so
    // a passphrase ending in one was altered on its way to the engine and
    // refused with nothing to say why.
    expect(
        msScript.contains("IFS= read -r -d '' __cred < '/tmp/ws/credential.fifo'"),
        "credential is read from the FIFO, exactly as it was typed")
    expect(
        !msScript.contains("$(cat '/tmp/ws/credential.fifo')"),
        "and not through a substitution that would trim it")
    expect(msScript.contains("ALFS_PASSPHRASE=\"$__cred\""), "credential passed by reference")
    expect(msScript.contains("unset __cred"), "credential is unset afterwards")

    // Without these the engine refuses to run: it is root but not via sudo.
    expect(msScript.contains("export SUDO_UID=501"), "invoking uid exported")
    expect(msScript.contains("export SUDO_GID=20"), "invoking gid exported")
    expect(msScript.contains("export DYLD_LIBRARY_PATH='/engine/lib'"), "dyld path exported")

    // Microsoft volumes try the kernel driver first, then ntfs-3g.
    //
    // ntfs3 is in the kernel, so its metadata is fast enough that deleting a
    // large folder finishes rather than crawling. It is safe over NFS:
    // generic_encode_ino32_fh puts the inode's generation in every handle and
    // ntfs_iget5 checks it against the MFT record's sequence number, so a
    // reused record is refused with -ESTALE rather than resolved to the wrong
    // file. It logs every refusal at error level, which reads alarmingly and
    // is not a failure.
    //
    // ntfs-3g is the fallback, for a volume Windows left dirty that ntfs3
    // refuses. It is FUSE, so it gets big_writes.
    expect(msScript.contains("-t ntfs3"), "ntfs3 attempted")
    expect(msScript.contains("-t ntfs-3g"), "ntfs-3g attempted as fallback")
    expect(
        msScript.range(of: "-t ntfs3")!.lowerBound < msScript.range(of: "-t ntfs-3g")!.lowerBound,
        "ntfs3 is tried before ntfs-3g")
    expect(
        msScript.contains("-t ntfs-3g -o big_writes"),
        "ntfs-3g is given big_writes")
    expect(
        !msScript.contains("-t ntfs3 -o big_writes"),
        "ntfs3 is not, having no FUSE crossing to amortise")
    expect(
        !msScript.contains("/usr/bin/expect"),
        "no LVM discovery for a Microsoft volume")

    // An alias cannot stand in for the device. The engine prefixes /dev/ onto
    // whatever target it is handed, so one under /tmp resolves to /dev//tmp/…
    // and the mount opens with "disk not found". Names come from DriveMemory,
    // and only an alias already under /dev is worth passing.
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

    // Paths with spaces must survive quoting, since they reach a root shell.
    // The workspace sits under a temporary directory that is not chosen here,
    // so such a path can occur.
    let msSpaces = MountScript.build(
        MountScript.Inputs(
            enginePath: "/eng/any linux fs", devicePath: "/dev/disk4s1", driveName: "D",
            kind: .linux, volume: nil, aliasPath: nil, fifoPath: "/tmp/My Space/fifo",
            logPath: "/tmp/My Space/mount.log", discoverLogPath: "/tmp/My Space/discover.log",
            expectScriptPath: "/tmp/My Space/discover.exp",
            configPath:
                "/Users/u/Library/Application Support/Lukotta/engine/.anylinuxfs/config.toml",
            engineHome: "/Users/u/Library/Application Support/Lukotta/engine",
            libraryPaths: ["/eng/li b"],
            uid: 501, gid: 20, cores: 4, ramMiB: 2560))
    expect(msSpaces.contains("'/tmp/My Space/mount.log'"), "spaces in paths stay quoted")
    expect(msSpaces.contains("'/eng/any linux fs'"), "spaces in the engine path stay quoted")
    expect(msSpaces.contains("'/tmp/My Space/discover.exp'"), "spaces in the expect path quoted")
}

group("multiVolumeServing") {

    // All volumes of a container are served from one microVM. The engine holds
    // an exclusive lock on the device for read-write mounts, so mounting each
    // volume in its own VM cannot work. The script generates a custom action
    // that mounts every volume onto tmpfs inside the VM and exports them
    // together, falling back to one volume at a time if that fails.
    let script = MountScript.build(sampleInputs(kind: .linux))

    expect(script.contains("-a lukotta"), "the generated action is selected for the mount")
    expect(script.contains("\"lvm:$__first\""), "one volume carries the primary mount")
    expect(script.contains("[custom_actions.lukotta]"), "the action section is generated")
    expect(script.contains("'/run/Elements'"), "the export scratch dir is named after the drive")
    expect(
        script.contains(#"mount -o bind \"$ALFS_VM_MOUNT_POINT\""#),
        "the primary volume is bound into the scratch dir, not re-mounted")
    expect(
        script.contains(
            "'/Users/u/Library/Application Support/Lukotta/engine/.anylinuxfs/config.toml'"),
        "the action is merged into the engine's config")
    // The engine is told where its own directory is, in the elevated shell,
    // because macOS strips the environment across a privilege boundary and an
    // engine that does not see this reads the shared one instead -- a different
    // image, and possibly another program's.
    expect(
        script.contains(
            "export ANYLINUXFS_HOME='/Users/u/Library/Application Support/Lukotta/engine'"),
        "and the engine is given this app's own directory to work in")
    expect(
        script.contains("LUKOTTA_VOLUMES:$(__new_mounts | grep -c .)"),
        "a combined mount counts the mounts that were not there before")
    expect(script.contains("\"lvm:$__lv\""), "the one-at-a-time fallback is still present")
    // Volumes that are not mountable filesystems would fail the combined mount.
    // Its after_mount stops at the first failure, so a half-served drive cannot
    // be presented as the whole one.
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

    // What makes a rollback impossible on an ordinary launch: with nothing kept
    // aside, the count is never read.
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

    // A first failed launch proves nothing. A power cut and a force quit leave
    // the same trace.
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
}

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

group("aLineOfTheMountTable") {
    // Five readers of this table used to find " on " and " (" for themselves.
    let line =
        "disk4s1.local:/mnt/BACKUP on /Volumes/BACKUP (nfs, nodev, nosuid, mounted by someone)"
    guard let entry = MountTableEntry(line: line) else {
        return expect(false, "an ordinary line is read")
    }
    expect(entry.source, "disk4s1.local:/mnt/BACKUP", "the source is what precedes \" on \"")
    expect(entry.mountPoint, "/Volumes/BACKUP", "the mount point is what follows it")
    expect(entry.options, "nfs, nodev, nosuid, mounted by someone", "the options are the brackets")
    expect(entry.isNFS, "an nfs mount says so")

    // A mount point with spaces in it, which Finder allows and this must not
    // truncate.
    guard let spaced = MountTableEntry(line: "/dev/disk9s2 on /Volumes/My Backup (ntfs3, local)")
    else { return expect(false, "a name with spaces is read") }
    expect(spaced.mountPoint, "/Volumes/My Backup", "spaces in a name survive")
    expect(!spaced.isNFS, "and a local filesystem is not nfs")

    expect(MountTableEntry(line: "") == nil, "a blank line is not a mount")
    expect(MountTableEntry(line: "nothing to see here") == nil, "nor is anything else")
    expect(
        "\(MountTableEntry.all(in: line + "\n\n" + line).count)", "2",
        "blank lines are skipped when reading a whole table")
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

    // The scratch export lives under /run, so those mounts are cleared when
    // their VM dies and left alone while it is alive.
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
    // The engine exits 0 on a failed mount, the status being its own shutdown
    // rather than the mount's. Every fallback is chained with ||, so an attempt
    // is judged by whether a mount appeared rather than by what the engine
    // returned.
    // Without this the first attempt always read as a success and nothing after
    // it ran: no ntfs-3g retry and no LVM discovery.
    let checked = MountScript.build(sampleInputs(kind: .linux))
    expect(checked.contains("__engine_mounts()"), "the engine's own mounts can be listed")
    expect(checked.contains("__rebase\n"), "a baseline is taken before anything is attempted")
    expect(
        checked.contains("2>&1 && __mounted"),
        "an attempt counts as success only if a mount appeared")
    // Compared by name rather than counted. A count is a count of everything,
    // including an NFS share the person using the Mac mounted themselves, and
    // one of those coming or going moves the number without a drive having been
    // opened.
    expect(!checked.contains("grep -cE"), "mounts are not counted")
    expect(checked.contains("grep -vxF -f"), "they are compared against the baseline")
    // The share is named for the device on a plain volume and for the volume
    // group on an LVM one, so there is no single name to look for either.
    expect(!checked.contains("disk4s1.local:"), "the check does not guess the share's name")
    let checkedMS = MountScript.build(sampleInputs(kind: .microsoft))
    expect(
        checkedMS.components(separatedBy: "&& __mounted").count - 1 == 6,
        "every attempt is verified: both NTFS drivers, both again after a slip, then both read-only"
    )
    // The extra one is the retry for a machine that slipped, and it must be
    // unreachable without the evidence for it. Unguarded, it would be a second
    // full attempt on every drive that cannot be written to.
    expect(
        checkedMS.contains("{ __slipped && sleep 2 &&"),
        "the retry happens only where the log says the machinery slipped")
    expect(
        checkedMS.contains("__slipped() {"),
        "and what counts as a slip is defined in the script rather than assumed")
    // Read-only was asked for: there is nothing to fall back to and nothing to
    // retry, so neither appears.
    let checkedRO = MountScript.build(sampleInputs(kind: .microsoft, readOnly: true))
    expect(
        !checkedRO.contains("__slipped"),
        "a mount asked for read-only has no write attempt to try again")

    // Which mounts are this app's own. A volume group is served as a tmpfs
    // under /run with the volumes bound inside it, and that shape was not
    // recognised -- so the sweep that takes down engines serving nothing would
    // have taken down the one serving somebody's root and home.
    let engineShapes = """
        disk4s1.local:/mnt/BACKUP on /Users/someone/Volumes/BACKUP (nfs, nodev)
        lvm-ubuntuvg.local:/run/Disk-Image on /Users/someone/Volumes/Disk-Image (nfs, nodev)
        127.0.0.4:/mnt/DATA on /Users/someone/Volumes/DATA (nfs, nodev)
        //someone@server/share on /Volumes/share (smbfs, nodev)
        /dev/disk4s2 on /Volumes/BACKUP (exfat, local)
        """
    let ours = MountTableEntry.all(in: engineShapes).filter(\.isEngineMount).map(\.mountPoint)
    expect(ours.count == 3, "a single volume, a volume group and a loopback export are all ours")
    expect(
        ours.contains("/Users/someone/Volumes/Disk-Image"),
        "the volume group's tmpfs under /run is one of them")
    expect(
        !ours.contains("/Volumes/share") && !ours.contains("/Volumes/BACKUP"),
        "and somebody else's share and a local disk are not")

    // A mount point is a place something is mounted, and nothing else. The
    // engine makes the directory before it mounts on it and leaves it there
    // when the mount fails, so "the path exists" answered yes for a drive that
    // had not opened: the person got an empty folder they could not write to
    // and no failure anywhere.
    let mountedSomewhere = """
        map auto_home on /System/Volumes/Data/home (autofs, automounted)
        disk4s1.local:/mnt/BACKUP on /Users/someone/Volumes/BACKUP (nfs, nodev)
        """
    expect(
        Set(MountTableEntry.all(in: mountedSomewhere).map(\.mountPoint))
            .contains("/Users/someone/Volumes/BACKUP"),
        "a mount in the table is a mount")
    expect(
        !Set(MountTableEntry.all(in: mountedSomewhere).map(\.mountPoint))
            .contains("/Users/someone/Volumes/Disk-Image"),
        "and a directory nobody mounted anything on is not, whatever is on disk")

    // The app keeps the outgoing version aside; the shim in front of it decides
    // whether to put it back. They have to agree about where it is, and did
    // not: one used the identifier, the other the name on disk, so a broken
    // update never rolled back. bundle_identifier() in main.c does the same as
    // this, and the fallback is what a bundle with no readable Info.plist gets.
    expect(
        AppRollback.supportName(identifier: "com.lukotta.beta", bundleName: "Lukotta Beta")
            == "com.lukotta.beta",
        "the identifier is what both sides file the kept-aside copy under")
    expect(
        AppRollback.supportName(identifier: nil, bundleName: "Lukotta Beta") == "Lukotta Beta",
        "and the name on disk when there is no identifier to read")
    expect(
        AppRollback.supportName(identifier: "", bundleName: "Drive Unlocker") == "Drive Unlocker",
        "an empty identifier counting as none")

    // A home the engine is given has to carry Library/Logs, because the engine
    // creates the home and not the log directory inside it -- and says only
    // "Failed to create log file: No such file or directory" about the
    // difference. Every route composes this path for itself, so it belongs to
    // the home rather than to whoever remembered.
    let madeUpHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("lukotta-home-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: madeUpHome) }
    expect(
        EngineEnvironment.makeHomeReady(at: madeUpHome),
        "a home the engine is handed can be made ready")
    expect(
        FileManager.default.fileExists(
            atPath: madeUpHome.appendingPathComponent("Library/Logs").path),
        "and it has the directory the engine opens its log in")

    // The app and the daemon have to compose one engine directory. The daemon
    // reads its own embedded identifier, which is the app's with ".helper" on
    // the end, and a directory of its own means a second Linux environment, a
    // second place for logs, and a drive served from neither.
    expect(
        EngineEnvironment.directoryName(identifier: "com.lukotta.helper", fileName: "Lukotta")
            == EngineEnvironment.directoryName(identifier: "com.lukotta", fileName: "Lukotta"),
        "the daemon and the app name the same engine directory")
    expect(
        EngineEnvironment.directoryName(identifier: "com.lukotta.beta.helper", fileName: "x")
            == "com.lukotta.beta",
        "and so do the pre-release and its own daemon")
    expect(
        EngineEnvironment.directoryName(identifier: nil, fileName: "Drive Unlocker")
            == "Drive Unlocker",
        "a build with no identifier falls back to the name on disk")

    // A mount whose server has gone looks exactly like a drive somebody has
    // open, and deciding wrongly either leaves the next mount wedged or takes
    // away a volume in use.
    let ourMount = "/Users/someone/Volumes/BACKUP"
    let serving = """
        map auto_home on /System/Volumes/Data/home (autofs, automounted)
        disk4s1.local:/mnt/BACKUP on \(ourMount) (nfs, nodev)
        """
    let mine: Set<String> = [ourMount]
    let noWait: (TimeInterval) -> Void = { _ in }
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine, answers: { _ in .alive }, pause: noWait
        ).isEmpty,
        "a mount that answers is a drive somebody has open")
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine, answers: { _ in .silent }, pause: noWait) == [ourMount],
        "one that answers neither time has lost its server, whatever is still running")
    expect(
        EngineProcesses.deadEngineMounts(
            in: "map auto_home on /System/Volumes/Data/home (autofs, automounted)",
            opened: mine, answers: { _ in .silent }, pause: noWait
        ).isEmpty,
        "and nothing but an engine mount is ever asked")
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: [], answers: { _ in .silent }, pause: noWait
        ).isEmpty,
        "a mount this app did not make is somebody else's to take down")
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine, answers: { _ in .couldNotAsk }, pause: noWait
        ).isEmpty,
        "a probe that could not be started says nothing about the mount")
    var asked = 0
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine,
            answers: { _ in
                asked += 1
                return asked == 1 ? .silent : .alive
            }, pause: noWait
        ).isEmpty,
        "one silence is a busy machine; only silence throughout is a server that has gone")

    // The window that matters. Two silences used to be enough, about five
    // seconds, and then `umount -f` and `rmdir` -- irreversible, on somebody's
    // copy. Measured against that: a microVM frozen by a busy Mac went forty
    // seconds without answering and came back serving its drive; a drive gone
    // slow was silent for fifteen minutes with its copy still viable. So a
    // mount that answers late still counts as alive.
    // A running microVM is not a server that has gone. Silence is what a slow
    // drive produces, and acting on silence alone unmounted a live drive
    // mid-copy on a 40 GB NTFS volume with the backing store starved -- twice,
    // the second time with every earlier fix already in.
    let serves =
        (try? String(contentsOfFile: "sources/LukottaCore/EngineProcesses.swift", encoding: .utf8))
        ?? ""
    expect(
        serves.contains("public static func serving() -> Set<Int32>"),
        "there is a way to ask whether any microVM is still serving")
    expect(
        serves.contains("arguments.contains(\" mount\")"),
        "and it means a mount process, not gvproxy, which outlives a failed mount")
    expect(
        serves.contains("if !serving().isEmpty {"),
        "nothing is called dead while a microVM is still running")

    var round = 0
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine,
            answers: { _ in
                round += 1
                return round <= 3 ? .silent : .alive
            }, pause: noWait
        ).isEmpty,
        "a mount silent three times and then answering is alive, not dead")
    var late = 0
    expect(
        EngineProcesses.deadEngineMounts(
            in: serving, opened: mine,
            answers: { _ in
                late += 1
                return late <= 5 ? .silent : .alive
            }, pause: noWait
        ).isEmpty,
        "and one that answers on the last probe is still alive")
    var counted = 0
    _ = EngineProcesses.deadEngineMounts(
        in: serving, opened: mine,
        answers: { _ in
            counted += 1
            return .silent
        }, pause: noWait)
    expect(counted >= 6, "a mount is asked at least six times before it is destroyed")
    var waited: [TimeInterval] = []
    _ = EngineProcesses.deadEngineMounts(
        in: serving, opened: mine, answers: { _ in .silent },
        pause: { waited.append($0) })
    expect(
        waited.reduce(0, +) >= 55,
        "spread over a minute, not five seconds")
    expect(
        EngineProcesses.isOursToForce(ourMount, opened: mine),
        "a mount point this app wrote down is its own to force")
    expect(
        !EngineProcesses.isOursToForce("/Volumes/Somebody Else", opened: []),
        "and one under /Volumes that it never made is not")

    // What counts as the machinery slipping, which decides whether somebody is
    // told their drive will not open or the attempt is quietly made again.
    expect(
        TransientFailure.isTransient(
            "macOS: Error: Failed to write to pipe: Broken pipe (os error 32)"),
        "a broken pipe is the machinery, not the drive")
    expect(
        TransientFailure.isTransient("Failed to acquire lock on image file: file already locked"),
        "an image still held by the last machine is worth another go")
    expect(
        TransientFailure.isTransient("\(TransientFailure.deadlineReached) 480 seconds"),
        "and so is an attempt this app ended itself")
    expect(
        !TransientFailure.isTransient("No key available with this passphrase"),
        "a wrong passphrase is an answer, and trying again wastes a minute")
    expect(
        !TransientFailure.isTransient("unknown filesystem type 'ntfs'"),
        "so is a filesystem nothing here can read")
    expect(
        !TransientFailure.isTransient("mount: /dev/disk4s1: Device busy"),
        "and a busy device says which drive it is about, so it is reported")

    // One list, read by the shell as well as by this.
    expect(
        TransientFailure.signatures.allSatisfy {
            TransientFailure.signaturesForTheScript.contains($0)
        },
        "the pattern the mount script greps with carries every signature")
    expect(
        !TransientFailure.signaturesForTheScript.contains("'"),
        "and nothing in it can close the quotes it is pasted inside")

    // What a transcript was about, before whether it contains a slip. Every
    // attempt tears a virtual machine down afterwards, and the teardown talks
    // like a slip all the way out -- including the one after a wrong passphrase.
    let refusedThenTornDown =
        (["No key available with this passphrase"]
        + Array(repeating: "shutting down", count: 8)
        + ["gvproxy: connection reset by peer", "vm exited"]).joined(separator: "\n")
    expect(
        !TransientFailure.endedInASlip(
            summary: "The passphrase did not unlock the drive.", detail: refusedThenTornDown),
        "a wrong passphrase is settled, whatever the teardown says on its way out")
    expect(
        TransientFailure.endedInASlip(
            summary: "The drive could not be opened.",
            detail: "Failed to write to pipe: Broken pipe (os error 32)\nvm exited"),
        "and a slip with nothing to explain it is worth another go")
    expect(
        TransientFailure.endedInASlip(
            summary: "The drive could not be opened.",
            detail: (Array(repeating: "unpacking", count: 200)
                + ["\(TransientFailure.deadlineReached) 480 seconds"]).joined(separator: "\n")),
        "an attempt this app ended itself says so, however long the transcript")
    expect(
        !TransientFailure.endedInASlip(
            summary: "The drive could not be opened.",
            detail: "unknown filesystem type 'exfat'\nconnection refused"),
        "a filesystem nothing here can read is an answer, not a slip")
    expect(
        TransientFailure.endedInASlip(
            summary: "The engine is already busy with another drive.",
            detail: "another instance is already running\nfailed to acquire lock"),
        "a lock held by an instance on its way out is the machinery, and is retried")

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
    // single apostrophe inside the awk program closed its quote and made every
    // multi-volume mount fail with no output, so the shell's own parser decides
    // whether it is valid.
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

    // Taken from a failure on a Fedora-style container: LUKS holding LVM holding
    // three volumes. The engine refuses to mount the container itself, and the
    // app turns that into a question rather than a failure.
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
            configPath: "/c", engineHome: "/h", libraryPaths: [], uid: 501, gid: 20,
            cores: 4, ramMiB: 2560))
    expect(!aliased.contains("/tmp/ws/alias"), "an unresolvable alias is not attempted")
    expect(aliased.contains("'/dev/disk5s1'"), "the device itself still is")

    // A mount left behind by a dead virtual machine must be recognisable without
    // matching anything mounted by the person using the Mac, since clearing one
    // of those would be worse than the fault this addresses.
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
    // indicator stuck on one step and then jumping several.
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

    // The helper redacts its transcript before handing it back, and that text
    // also drives the step indicator. Redaction that damaged a marker would
    // leave the steps stuck with nothing else appearing wrong.
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
    // The notices are shown in the app, so the parser must handle the constructs
    // the file uses rather than presenting raw Markdown.
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
        case .rule, .code: break
        }
    }
    expect(headings == 2, "both headings parsed")
    expect(paragraphs == 1, "paragraph parsed")
    expect(tables == 1, "table parsed")
    expect(bullets == 1, "bullet list parsed")
    expect(MarkdownDocument.parse("").isEmpty, "empty document yields no blocks")

    // A wrapped bullet is one bullet rather than a bullet and a loose
    // paragraph.
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

group("anImageWithASpaceInItsNameIsStillReadable") {
    // The engine reads a path as far as its first space, so an image called
    // "Open Drive.vdi" is reported as a file with nothing in it. A link with no
    // space stands in for it.
    let plain = URL(fileURLWithPath: "/tmp/lukotta-check/plain.vdi")
    expect(DiskImage.withoutSpaces(plain) == plain, "a path with no space is handed over as it is")

    let spaced = URL(fileURLWithPath: "/tmp/lukotta check/Open Drive.vdi")
    let stand = DiskImage.withoutSpaces(spaced)
    expect(!stand.path.contains(" "), "one with a space is replaced by a path without one")
    expect(stand.pathExtension == "vdi", "the extension is kept, formats being told apart by it")
    expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: stand.path)) == spaced.path,
        "and the link points at the file itself")

    let other = URL(fileURLWithPath: "/tmp/elsewhere/Open Drive.vdi")
    expect(
        DiskImage.withoutSpaces(other).lastPathComponent != stand.lastPathComponent,
        "two images of the same name in different folders do not collide")
    try? FileManager.default.removeItem(at: stand)
    try? FileManager.default.removeItem(at: DiskImage.withoutSpaces(other))
}

group("aSynthesisedContainerIsNotAContainerFile") {
    // Every Mac has three synthesised APFS containers, and diskutil calls them
    // Virtual -- the same word it uses for a disk image. Read as container
    // files they were offered as drives to unlock, so somebody was invited to
    // open their own Recovery volume. The bus says which is which.
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk3",
                "APFSVolumes": [
                    [
                        "DeviceIdentifier": "disk3s3", "Content": "Apple_APFS",
                        "VolumeName": "Recovery",
                        "Size": NSNumber(value: 494_000_000),
                    ],
                    [
                        "DeviceIdentifier": "disk3s6", "Content": "Apple_APFS",
                        "VolumeName": "Update",
                        "Size": NSNumber(value: 5_370_000_000),
                    ],
                ],
            ]
        ]
    ]
    let rows = DriveSurvey.survey(
        list: plist,
        info: { _ in
            [
                "BusProtocol": "Apple Fabric", "VirtualOrPhysical": "Virtual",
                "Internal": true,
            ]
        },
        mountTable: "", openable: [])
    expect(rows.count == 2, "both volumes are listed")
    expect(
        rows.allSatisfy { $0.verdict == .system },
        "and both belong to the system, whatever diskutil calls the container")
    expect(rows.allSatisfy { $0.drive == nil }, "so neither is offered as a drive to open")
}

group("aRowSaysOnlyWhatIsKnownAboutIt") {
    // A partition type is worth two possibilities and the row says both. A disk
    // with no partition table has no type at all -- a stick somebody ran
    // cryptsetup or mkfs over, or BitLocker written without a table -- and a
    // row that guesses there said LUKS over a plain ext4 stick.
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk4", "Size": NSNumber(value: 64_000_000_000)]
        ]
    ]
    let rows = DriveScanner.drives(
        inList: plist,
        info: { _ in ["BusProtocol": "USB", "Internal": false] })
    expect(rows.count == 1, "an unpartitioned disk is offered")
    expect(rows.first?.kindIsKnown == false, "and says nothing about what is in it")

    let partitioned: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk4s1", "Content": "Linux Filesystem",
                        "Size": NSNumber(value: 64_000_000_000),
                    ]
                ],
            ]
        ]
    ]
    let typed = DriveScanner.drives(
        inList: partitioned, info: { _ in ["BusProtocol": "USB", "Internal": false] })
    expect(typed.first?.kindIsKnown == true, "a partition type is worth saying")
    expect(
        typed.first?.kind.summary == "LUKS/Linux",
        "and it is the pair, since the type allows either")
}

group("aLanguageSpokenInAnotherCountryFindsItsTranslation") {
    // Nobody's Mac is set to plain "es". It is set to Spanish (Mexico), German
    // (Austria), Arabic (Egypt), and macOS matches those against what a bundle
    // carries. That matching is Foundation's, and it is asked here directly:
    // the thing that can break it is a folder named in some other style than
    // Apple's, which no other check would notice.
    let shipped =
        ((try? FileManager.default.contentsOfDirectory(atPath: "translations")) ?? [])
        .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    expect(shipped.count >= 30, "the translations are where this expects them")

    func chosen(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: shipped + ["en"], forPreferences: preferences).first
            ?? "—"
    }
    // A language written the same way wherever it is spoken.
    expect(chosen(["es-MX"]), "es", "Spanish in Mexico is Spanish")
    expect(chosen(["es-419"]), "es", "and so is Latin American Spanish")
    expect(chosen(["de-AT"]), "de", "German in Austria is German")
    expect(chosen(["ar-EG"]), "ar", "Arabic in Egypt is Arabic")
    expect(chosen(["fr-CA"]), "fr", "French in Canada is French")
    expect(chosen(["pt-BR"]), "pt-PT", "Brazilian Portuguese takes the Portuguese there is")
    expect(chosen(["zh-Hans-SG"]), "zh-Hans", "Simplified Chinese in Singapore")
    // Codes that were renamed, and which some systems still send.
    expect(chosen(["iw"]), "he", "Hebrew's old code")
    expect(chosen(["in"]), "id", "Indonesian's old code")
    expect(chosen(["tl"]), "fil", "Tagalog asks for Filipino")
    expect(chosen(["nn-NO"]), "nb", "Nynorsk takes Bokmål")
    // A language this app does not have, with a second choice behind it, which
    // is how a Mac in Catalonia or Kazakhstan is actually set up.
    expect(chosen(["ca-ES", "es-ES"]), "es", "Catalan falls to the next language asked for")
    expect(chosen(["kk-KZ", "ru-RU"]), "ru", "and Kazakh to Russian")
    expect(chosen(["fa-IR", "en-US"]), "en", "and English where there is nothing nearer")
}

group("nothingTalksToTheHelperOffTheSafePath") {
    // XPC calls the reply and the error handler on its own queue. A closure
    // written inside a @MainActor method carries that isolation, and running it
    // anywhere else traps under Swift 6 and takes the app down. It has happened
    // twice: once on a mount, and once on the first launch after a method the
    // running helper did not have yet.
    //
    // roundTrip is the one path that is safe to answer from that queue, so what
    // is checked is that nothing calls the proxy directly.
    let client =
        (try? String(contentsOfFile: "sources/Lukotta/HelperClient.swift", encoding: .utf8)) ?? ""
    expect(!client.isEmpty, "the client is where this expects it")
    // The shape that crashed, twice: take the proxy in a main-actor method,
    // hold it in a variable, and call a method on it. The reply and the error
    // both then run a main-actor closure on XPC's queue. Inside roundTrip the
    // proxy is a parameter, never a variable taken here.
    expect(
        !client.contains("let proxy = proxy()"),
        "no call into the helper is made on a proxy held in a variable")
    expect(
        client.contains("private nonisolated static func roundTrip"),
        "and the one safe path is still here")
}

group("oneScrubberAndNothingGoesRoundIt") {
    // Everything shown, stored, logged or sent goes through one function. It
    // was two, applied in different combinations at eight call sites, so a
    // failure's summary kept the markers its detail had stripped and nothing
    // stripped the account name at all.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let text = """
        LUKOTTA_STAGE:working
        opening \(home)/Pictures/holiday.img
        passphrase: hunter2
        recovery key 123456-234567-345678-456789-567890-678901-789012-890123
        """
    let clean = Diagnostics.scrubbed(text, secret: "swordfish")
    expect(!clean.contains("LUKOTTA_"), "this app's own markers do not leave it")
    expect(!clean.contains(home), "nor does the path to somebody's home")
    expect(clean.contains("~/Pictures/holiday.img"), "the path is still readable")
    expect(clean.contains("holiday.img"), "and the file is still named, which is the report")
    expect(!clean.contains("hunter2"), "a labelled secret goes")
    expect(!clean.contains("123456-234567"), "and so does a recovery key")
    expect(
        Diagnostics.scrubbed("it was swordfish", secret: "swordfish") == "it was [redacted]",
        "and the credential itself, by value")

    // The account name on its own, not as part of a path.
    let account = String(home.dropFirst("/Users/".count))
    if account.count >= 3 {
        expect(
            !Diagnostics.scrubbed("mounted by \(account)").contains(" \(account)"),
            "the account name goes wherever it appears")
    }

    // Nothing may call the halves directly: that is how the combinations
    // drifted apart in the first place.
    for file in [
        "sources/Lukotta/AppModel.swift", "sources/LukottaHelper/main.swift",
        "sources/Lukotta/Views/ReportIssueSheet.swift",
    ] {
        let source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        expect(!source.isEmpty, "\(file) is where this expects it")
        expect(
            !source.contains("Diagnostics.redact")
                && !source.contains("Diagnostics.withoutMarkers"),
            "\(file) scrubs through the one function")
    }
}

group("uninstallingTakesEverythingWithIt") {
    // What the uninstall touches, checked against what the app writes. A thing
    // added to one and not the other is how an app comes to leave a folder
    // behind for years.
    let uninstall =
        (try? String(contentsOfFile: "sources/Lukotta/Uninstall.swift", encoding: .utf8)) ?? ""
    expect(!uninstall.isEmpty, "the uninstall is where this expects it")
    for what in [

        "applicationSupportDirectory",  // what the app kept
        "cachesDirectory",  // what Sparkle kept, in this app's name
        "removePersistentDomain",  // every setting, including the ones added since
        "CredentialStore.delete",  // the saved passphrases, when asked
        "releaseRoom",  // the loopback addresses the helper added
        "Housekeeping.sweep",  // the scratch directories and mount points
        "EngineEnvironment.engineHome",  // this app's own Linux environment
        "unregister",  // the daemon
        "moveToTheBin",  // and the app itself
    ] {
        expect(uninstall.contains(what), "uninstalling deals with \(what)")
    }
}

group("aRefusedPermissionSaysWhichOneAndOffersTheWayToIt") {
    // The one failure that cannot be produced in an end-to-end run: Full Disk
    // Access is granted by hand and cannot be taken away by a program. What can
    // be checked is the decision it leads to -- the sentence names the
    // permission, and the failure screen offers the button that opens the pane,
    // which it chooses by looking for that name.
    let refused = """
        macOS: probing /dev/disk4s1
        macOS: Error: Cannot probe /dev/disk4s1: LibErr(0); Insufficient permissions?
        """
    let rule = Diagnosis.rule(for: refused)
    expect(
        rule?.name == "no-full-disk-access", "a refusal by macOS is recognised as the permission")
    let summary = Diagnosis.summarise(refused, fallback: "")
    expect(summary.contains("Full Disk Access"), "and the sentence names it")
    // The screen picks its button by that name, so the two have to agree.
    expect(
        summary.contains("Full Disk Access"),
        "which is what puts Open Privacy Settings on the failure screen")
}

group("theHelperAndTheAppAgreeOnWhoTheyAre") {
    // The helper carries its own Info.plist inside the binary, because
    // SMJobBless requires one -- and an embedded plist wins over the bundle the
    // executable sits in, so the helper reads its own identifier where it used
    // to read the app's. Everything is composed from the app's: the mach
    // service, the requirement each side demands of the other, the paths the
    // daemon removes itself from.
    //
    // Left alone, the helper listened on <id>.helper.helper, refused the only
    // app allowed to talk to it, and looked for itself where it was not. A
    // daemon that installs and then serves nobody, with nothing on any screen
    // saying why.
    expect(
        HelperInfo.identifierOfTheApp(behind: "com.lukotta.helper") == "com.lukotta",
        "the helper reading its own identifier arrives at the app's")
    expect(
        HelperInfo.identifierOfTheApp(behind: "com.lukotta.beta.helper") == "com.lukotta.beta",
        "and so does the beta's, which is a different app again")
    expect(
        HelperInfo.identifierOfTheApp(behind: "com.lukotta") == "com.lukotta",
        "the app's own identifier is left as it is")
    expect(
        HelperInfo.identifierOfTheApp(behind: "com.helpful.app") == "com.helpful.app",
        "and an identifier that merely contains the word is not truncated")

    // What the two sides then compose, which has to match exactly or the
    // connection is refused by the one side and never offered by the other.
    expect(
        HelperInfo.machServiceName == HelperInfo.appIdentifier + ".helper",
        "the mach service is the app's identifier with one suffix, not two")
    expect(
        HelperInfo.installedJobPath.hasSuffix("/\(HelperInfo.machServiceName).plist"),
        "the job the daemon removes is the job it was installed as")
    expect(
        HelperInfo.installedToolPath.hasSuffix("/\(HelperInfo.machServiceName)"),
        "and the binary it removes is the one that was installed")
    expect(
        HelperInfo.clientRequirement(team: "A1B2C3D4E5")?
            .contains("identifier \"\(HelperInfo.appIdentifier)\"") == true,
        "the requirement names the app, which is who connects")
}

group("theFirstScreenIsTheRightOneStraightAway") {
    // Reading the permission opens files, so it happens off the main thread --
    // which is a whole screen too late to decide what to draw. The app opened
    // on the drive list and replaced it with the permission screen once the
    // answer came back, so the first thing anybody saw on a new install was a
    // flicker of a list they cannot have.
    let key = Permissions.grantedKey
    let before = UserDefaults.standard.object(forKey: key)
    defer {
        if let before {
            UserDefaults.standard.set(before, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    UserDefaults.standard.removeObject(forKey: key)
    expect(
        !Permissions.wasGranted,
        "a Mac that has never run this app is assumed not to have granted it")
    Permissions.wasGranted = true
    expect(Permissions.wasGranted, "and what was granted is remembered")
    Permissions.wasGranted = false
    expect(!Permissions.wasGranted, "and what was taken away is remembered too")

    // Written by the reading itself, so nothing else has to remember to.
    let reading = Permissions.reading()
    expect(
        Permissions.wasGranted == reading.fullDiskAccess,
        "every reading records what it found for the next launch to open with")

    // Granting the permission makes macOS quit the app, so the next launch is
    // the one whose record is stale. Opening on the permission screen and
    // replacing it half a second later is what somebody sees straight after
    // doing what that screen asked -- so a "no" on record is looked at again
    // before anything is drawn, and a "yes" is taken as it stands.
    UserDefaults.standard.removeObject(forKey: key)
    expect(
        Permissions.likelyGranted() == Permissions.reading().fullDiskAccess,
        "with nothing on record the disk decides, not the flicker")
    expect(
        Permissions.wasGranted == Permissions.likelyGranted(),
        "and the answer is written down, so the next launch costs nothing")
    Permissions.wasGranted = true
    expect(
        Permissions.likelyGranted(),
        "a permission granted before is believed without touching the disk")
}

group("aBetaAndAReleaseShareNothingThatMatters") {
    // The two are installed side by side on purpose, so every place either
    // keeps something has to be keyed to which one it is. What is derived from
    // the bundle is checked here; what is keyed by bundle identifier -- the
    // settings, the Keychain service, the helper's own service name, the log
    // subsystem, Sparkle's cache -- is separated by macOS itself, given the
    // identifiers differ, which build-app.sh sets and its own case statement
    // keeps apart.
    let beta = "Lukotta Beta"
    let release = "Lukotta"
    let home = "/Users/someone"

    // Where the engine keeps the image, the configuration and the logs.
    expect(
        EngineEnvironment.engineHome(inHome: home, named: beta)
            != EngineEnvironment.engineHome(inHome: home, named: release),
        "the Linux environment of one is not the Linux environment of the other")
    expect(
        !EngineEnvironment.engineHome(inHome: home, named: beta).path
            .hasPrefix(EngineEnvironment.engineHome(inHome: home, named: release).path),
        "and neither sits inside the other, where deleting one would take the other")

    // The scratch directory of a mount, which is swept by name.
    expect(
        Workspace.prefix.contains(Bundle.main.bundleIdentifier ?? "com.lukotta"),
        "a mount's workspace is named after the application that made it")

    // The mounts themselves. Both serve into ~/Volumes, and the engine's status
    // reports every mount on the Mac whoever made it, so uninstalling one
    // offered to eject the other's drives -- and then ejected them.
    UserDefaults.standard.removeObject(forKey: OpenedHere.key)
    defer { UserDefaults.standard.removeObject(forKey: OpenedHere.key) }
    OpenedHere.add("/Users/someone/Volumes/MINE")
    let reported = ["/Users/someone/Volumes/MINE", "/Users/someone/Volumes/THEIRS"]
    expect(
        OpenedHere.ours(of: reported) == ["/Users/someone/Volumes/MINE"],
        "only the mounts this copy made are this copy's to eject")
    OpenedHere.remove("/Users/someone/Volumes/MINE")
    expect(OpenedHere.ours(of: reported).isEmpty, "and ejecting one takes it off the list")

    OpenedHere.add("/Users/someone/Volumes/GONE")
    expect(
        OpenedHere.forgetWhatIsGone(mountTable: "") == 1,
        "a mount point that is no longer mounted is forgotten rather than kept for ever")
}

group("aV2BuildCannotReachAnythingOfV1s") {
    // v2 is the FSKit rewrite, written and installed beside the channels v1
    // goes on being fixed on. build-app.sh makes it a different application --
    // "Lukotta v2" under com.lukotta.v2, with its own daemon -- and everything
    // either of them keeps is filed under one of those two values. So what is
    // checked here is the filing, not the intention.
    //
    // The identifier is the part that needs checking rather than asserting.
    // "com.lukotta.v2" begins with "com.lukotta" and "Lukotta v2" begins with
    // "Lukotta", so anything matching on the start of a value rather than on
    // the whole of it would have the release sweeping up the rewrite's
    // directories, or the rewrite's daemon answering as the release's. Neither
    // would look like a mistake until months of work were in the way.
    let channels = [
        (name: "Lukotta", identifier: "com.lukotta"),
        (name: "Lukotta Beta", identifier: "com.lukotta.beta"),
        (name: "Lukotta Dev", identifier: "com.lukotta.dev"),
        (name: "Lukotta v2", identifier: "com.lukotta.v2"),
        (name: "Drive Unlocker", identifier: "com.example.driveunlocker"),
    ]
    let home = "/Users/someone"

    // Application Support: the Linux environment, the engine's logs, and the
    // copy kept aside to put a bad update back.
    let homes = channels.map {
        EngineEnvironment.engineHome(
            inHome: home,
            named: EngineEnvironment.directoryName(identifier: $0.identifier, fileName: $0.name)
        ).path
    }
    expect(
        Set(homes).count == channels.count,
        "every channel keeps its Linux environment in a directory of its own")
    for mine in homes {
        expect(
            !homes.contains { $0 != mine && mine.hasPrefix($0 + "/") },
            "and none sits inside another, where deleting one would take the other")
    }

    // Where the rest of what a build keeps is filed: preferences, the Keychain
    // service holding saved passphrases, Sparkle's cache, the log subsystem.
    // macOS separates all of those by identifier itself, given the identifiers
    // differ, so this checks that they do.
    let supports = channels.map {
        AppRollback.supportName(identifier: $0.identifier, bundleName: $0.name)
    }
    expect(Set(supports).count == channels.count, "and files everything else under its own name")

    // The daemon. Its label is the identifier with .helper after it, and the
    // app behind a daemon is worked out by taking that suffix off -- exactly,
    // not by looking for a value the label starts with.
    for channel in channels {
        expect(
            HelperInfo.identifierOfTheApp(behind: "\(channel.identifier).helper")
                == channel.identifier,
            "the daemon of \(channel.name) belongs to \(channel.name)")
    }
    expect(
        HelperInfo.identifierOfTheApp(behind: "com.lukotta.v2.helper") != "com.lukotta",
        "and the rewrite's daemon is not the release's, though its identifier sits under it")

    // The scratch directory a mount makes, which is swept by name at launch.
    // The sweep matches on the start of the name, and this is what stops the
    // release's sweep taking a mount the rewrite has open: the prefix ends in a
    // hyphen, and what follows com.lukotta in com.lukotta.v2 is a dot.
    let scratch = { (identifier: String) in "Lukotta-\(identifier)-" }
    expect(
        Workspace.prefix == scratch(Bundle.main.bundleIdentifier ?? "com.lukotta"),
        "a mount's scratch directory is named after the identifier")
    expect(
        !scratch("com.lukotta.v2").hasPrefix(scratch("com.lukotta")),
        "so the release cannot mistake the rewrite's scratch directories for its own")
}

group("theFilesystemBehindTheExtensionKeepsItsPromises") {
    // What the FSKit module answers the kernel with. Every one of these is a
    // promise the VFS makes to whoever is using the drive, and getting one
    // wrong shows up as a folder that looks empty, a file that will not open,
    // or a rename that loses the file rather than as an error anybody can read.
    let store = FSStore()
    let root = store.root

    expect(root.isDirectory, "the root is a directory")
    expect(store.lookup("nothing", in: root) == nil, "and starts empty")

    // Creating, and refusing to create twice.
    let file = store.create("report.txt", isDirectory: false, in: root, mode: 0o644)
    expect(file != nil, "a file can be made")
    expect(
        store.create("report.txt", isDirectory: false, in: root, mode: 0o644) == nil,
        "and the same name cannot be made twice -- that is EEXIST, not a second file")
    expect(store.lookup("report.txt", in: root) === file, "looking it up finds the same item")

    // Identity. FSKit hands an item back on every later call and expects it to
    // still mean the same file, so two files may never share an id.
    let other = store.create("other.txt", isDirectory: false, in: root, mode: 0o644)
    expect(file?.id != other?.id, "no two items share an identifier")

    // Directories, and the link count Finder reads to decide a folder is empty.
    let folder = store.create("Photos", isDirectory: true, in: root, mode: 0o755)!
    expect(folder.linkCount == 2, "a new directory links to itself and its parent")
    _ = store.create("Trip", isDirectory: true, in: folder, mode: 0o755)
    expect(folder.linkCount == 3, "and gains one for each directory inside it")

    // Removing. Each outcome is a different errno, and the wrong one is a
    // dialog that says the wrong thing.
    expect(store.remove("absent", from: root) == .missing, "removing what is not there is ENOENT")
    expect(
        store.remove("Photos", from: root) == .notEmpty,
        "a directory with anything in it is ENOTEMPTY")
    expect(store.remove("Trip", from: folder) == .removed, "an empty one goes")
    expect(store.remove("Photos", from: root) == .removed, "and then so does its parent")

    // Writing, reading back, and growing into a hole.
    let data = Data("hello".utf8)
    expect(
        store.write(file!, contents: data, offset: 0) == data.count, "a write reports what it took")
    expect(store.read(file!, offset: 0, length: 99) == data, "and reads back exactly that")
    expect(
        store.read(file!, offset: 3, length: 99) == data.dropFirst(3),
        "reading from an offset skips")
    expect(
        store.read(file!, offset: 99, length: 10).isEmpty,
        "reading past the end is empty, not an error")
    _ = store.write(file!, contents: Data("!".utf8), offset: 10)
    expect(file!.size == 11, "a write past the end grows the file")
    expect(store.read(file!, offset: 5, length: 5) == Data(count: 5), "and the gap reads as zeroes")

    store.truncate(file!, to: 2)
    expect(file!.size == 2, "truncating shortens it")
    store.truncate(file!, to: 6)
    expect(file!.size == 6, "and truncating upwards grows it")

    // Renaming, including the move-to-Trash case: across directories, over
    // something already there.
    let trash = store.create(".Trashes", isDirectory: true, in: root, mode: 0o700)!
    expect(
        store.rename("report.txt", in: root, to: "report.txt", in: trash),
        "a file moves to another directory")
    expect(store.lookup("report.txt", in: root) == nil, "and is gone from where it was")
    expect(store.lookup("report.txt", in: trash) === file, "and is the same item where it landed")
    expect(file?.parent === trash, "with its parent updated, which is what fileID/parentID report")
    expect(
        !store.rename("absent", in: root, to: "x", in: trash),
        "renaming what is not there fails rather than inventing a file")

    // Enumeration order. FSKit resumes a directory listing from a cookie that
    // is an index into this, so an order that moves between calls skips
    // entries -- a folder that shows some of its files and not others.
    let listing = store.create("many", isDirectory: true, in: root, mode: 0o755)!
    for name in ["delta", "alpha", "charlie", "bravo"] {
        _ = store.create(name, isDirectory: false, in: listing, mode: 0o644)
    }
    let first = store.children(of: listing).map(\.name)
    expect(first == ["alpha", "bravo", "charlie", "delta"], "children come back sorted")
    expect(store.children(of: listing).map(\.name) == first, "and in the same order every time")

    // Extended attributes, stored natively. This is the whole reason a
    // Lukotta volume would stop collecting AppleDouble sidecars: macOS puts
    // com.apple.provenance on every file it makes, and a filesystem that
    // cannot hold it gets a ._name file beside every single file instead --
    // measured on the NFS volume today, 6000 files and 6000 sidecars.
    let target = store.create("tagged", isDirectory: false, in: root, mode: 0o644)!
    expect(store.xattrNames(of: target).isEmpty, "a new file carries none")
    expect(store.xattr("com.apple.provenance", of: target) == nil, "and asking gives nothing")

    let prov = Data([0x01, 0x02])
    expect(store.setXattr("com.apple.provenance", to: prov, on: target) == .set, "one can be set")
    expect(store.xattr("com.apple.provenance", of: target) == prov, "and read back")
    expect(store.xattrNames(of: target) == ["com.apple.provenance"], "and listed")

    // The policies. A create that quietly overwrites loses what was there, and
    // a replace that quietly creates invents an attribute nobody set.
    expect(
        store.setXattr("com.apple.provenance", to: prov, on: target, mustCreate: true) == .exists,
        "creating one that exists is EEXIST rather than an overwrite")
    expect(
        store.setXattr("absent", to: prov, on: target, mustReplace: true) == .missing,
        "replacing one that does not exist is ENOATTR rather than a new attribute")
    expect(
        store.setXattr("second", to: prov, on: target, mustCreate: true) == .set,
        "creating a new one is allowed")
    expect(store.xattrNames(of: target) == ["com.apple.provenance", "second"], "listed in order")

    // Removal is a set to nil, which is how removexattr arrives.
    expect(store.setXattr("second", to: nil, on: target) == .set, "setting nil removes it")
    expect(store.xattrNames(of: target) == ["com.apple.provenance"], "and it is gone")
    expect(
        store.setXattr("second", to: nil, on: target) == .missing,
        "removing it twice is ENOATTR, not silence")

    // What statfs reports. A volume claiming no free space is one Finder will
    // not copy onto.
    let usage = store.usage()
    expect(usage.files > 0, "the volume counts what is on it")
    expect(usage.bytes >= 6, "including the bytes")
}

group("theExtensionCanServeSomewhereRealAsWellAsMemory") {
    // FSStore holds its files in memory, which prices the framework and nothing
    // else. This one keeps them in a real directory, which is what lets the
    // write path be measured against a backing store that is not the
    // bottleneck -- and it is the shape of the real thing, where what is behind
    // the module is a guest holding the volume rather than a dictionary.
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("passthrough-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let store = FSPassthrough(root: base)
    guard let root = store.rootEntry() else {
        expect(false, "the root has to be readable")
        return
    }
    expect(root.isDirectory, "the root is a directory")

    // A name from the kernel is one component and never a path. One carrying a
    // slash or .. would reach outside the volume entirely, which in a process
    // that answers the filesystem is the whole of a directory traversal.
    expect(!FSPassthrough.isSafe("../escape"), "a name that climbs out is refused")
    expect(!FSPassthrough.isSafe("a/b"), "so is one with a separator in it")
    expect(!FSPassthrough.isSafe(""), "and an empty one")
    expect(FSPassthrough.isSafe("Report 2026.txt"), "an ordinary name is fine")
    expect(
        store.create("../escape", isDirectory: false, in: root, mode: 0o644) == nil,
        "and creating through one fails rather than writing outside the volume")

    // Identity has to survive a rename, so it cannot come from the path. The
    // inode is what the filesystem underneath already uses for this.
    let file = store.create("report.txt", isDirectory: false, in: root, mode: 0o644)
    expect(file != nil, "a file can be made")
    expect(
        store.create("report.txt", isDirectory: false, in: root, mode: 0o644) == nil,
        "and the same name twice is EEXIST")
    let before = file?.id
    let folder = store.create("Archive", isDirectory: true, in: root, mode: 0o755)!
    expect(store.rename("report.txt", in: root, to: "report.txt", in: folder), "it moves")
    expect(
        store.lookup("report.txt", in: folder)?.id == before,
        "and is the same item afterwards, which is what FSKit holds on to")
    expect(store.lookup("report.txt", in: root) == nil, "and gone from where it was")

    // Contents, including a write past the end.
    let moved = store.lookup("report.txt", in: folder)!
    let data = Data("hello".utf8)
    expect(
        store.write(moved, contents: data, offset: 0) == data.count, "a write reports what it took")
    expect(store.read(moved, offset: 0, length: 99) == data, "and reads back exactly that")
    expect(store.read(moved, offset: 99, length: 10).isEmpty, "past the end is empty, not an error")
    _ = store.write(moved, contents: Data("!".utf8), offset: 10)
    expect(store.lookup("report.txt", in: folder)?.size == 11, "a write past the end grows it")
    store.truncate(moved, to: 2)
    expect(store.lookup("report.txt", in: folder)?.size == 2, "truncating shortens it")

    // Removal outcomes, each a different errno.
    expect(store.remove("absent", from: root) == .missing, "what is not there is ENOENT")
    expect(store.remove("Archive", from: root) == .notEmpty, "a directory with something in it")
    expect(store.remove("report.txt", from: folder) == .removed, "the file goes")
    expect(store.remove("Archive", from: root) == .removed, "and then the directory")

    // Extended attributes, answered natively so the volume never collects
    // AppleDouble sidecars.
    let tagged = store.create("tagged", isDirectory: false, in: root, mode: 0o644)!
    let value = Data([0x01, 0x02])
    expect(store.setXattr("com.lukotta.test", to: value, on: tagged) == .set, "one can be set")
    expect(store.xattr("com.lukotta.test", of: tagged) == value, "and read back")
    expect(store.xattrNames(of: tagged).contains("com.lukotta.test"), "and listed")
    expect(
        store.setXattr("com.lukotta.test", to: value, on: tagged, mustCreate: true) == .exists,
        "creating one that exists is EEXIST rather than an overwrite")
    expect(store.setXattr("com.lukotta.test", to: nil, on: tagged) == .set, "nil removes it")
    expect(!store.xattrNames(of: tagged).contains("com.lukotta.test"), "and it is gone")

    // Enumeration order, which FSKit's directory cookie is an index into.
    for name in ["delta", "alpha", "charlie"] {
        _ = store.create(name, isDirectory: false, in: root, mode: 0o644)
    }
    let listing = store.children(of: root).map { $0.url.lastPathComponent }
    expect(
        listing == listing.sorted(), "children come back sorted, so a resumed listing skips nothing"
    )
}

group("aDriveGetsATrashSoDeletingIsARename") {
    // Finder does not delete when somebody presses command-delete: it renames
    // into .Trashes/<uid> at the top of the volume, which costs the same
    // whether the folder holds one file or a million. Where it cannot, it
    // unlinks one at a time and gives up part way with "some items had to be
    // skipped", which is what a Lukotta drive did for its whole life: 4028 ms
    // for six thousand files, against 2.9 ms for the rename.
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("trash-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let volume = base.path

    expect(
        Trash.prepare(onVolumeAt: volume, readOnly: false, uid: 501),
        "a writable volume gets a trash directory")
    var isDirectory: ObjCBool = false
    expect(
        FileManager.default.fileExists(
            atPath: Trash.directory(onVolumeAt: volume, uid: 501), isDirectory: &isDirectory)
            && isDirectory.boolValue,
        "and it is where Finder looks for it, .Trashes/<uid>")

    // Somebody else's deleted files are not ours to read.
    let mode =
        (try? FileManager.default.attributesOfItem(
            atPath: Trash.directory(onVolumeAt: volume, uid: 501))[.posixPermissions]) as? NSNumber
    expect(mode?.int16Value == 0o700, "readable by whoever opened the drive and nobody else")

    // Asked twice is the ordinary case: every mount of a drive somebody uses.
    expect(
        Trash.prepare(onVolumeAt: volume, readOnly: false, uid: 501),
        "preparing one that is already there is not a failure")

    // A read-only drive cannot take one, and must not be asked -- a write error
    // in the log of every read-only mount is noise that means nothing.
    let readOnlyVolume = base.appendingPathComponent("ro").path
    expect(
        !Trash.prepare(onVolumeAt: readOnlyVolume, readOnly: true, uid: 501),
        "a read-only drive is not asked for one")
    expect(
        !FileManager.default.fileExists(atPath: readOnlyVolume + "/.Trashes"),
        "and nothing is written to it")

    // A volume that will not take one is the old behaviour, not a broken mount.
    expect(
        !Trash.prepare(onVolumeAt: "/dev/null/nowhere", readOnly: false, uid: 501),
        "a volume that refuses one says so rather than throwing")
}

group("theEngineWorksInThisAppsOwnDirectoryAndNobodyElses") {
    // The engine as published keeps everything under ~/.anylinuxfs, which is
    // one directory for every program on the Mac that uses it: a release, a
    // beta, and anylinuxfs installed on its own. Each ships the image its own
    // engine was built against, so sharing means each of them finding an image
    // it did not put there. The engine this app carries is patched to take that
    // directory from ANYLINUXFS_HOME, and this is what it is given.
    let home = EngineEnvironment.engineHome(inHome: "/Users/someone", named: "Lukotta Beta")
    expect(
        home.path == "/Users/someone/Library/Application Support/Lukotta Beta/engine",
        "the engine works inside this app's own Application Support directory")
    expect(
        !home.path.contains("/.anylinuxfs"),
        "and not in the one every program using this engine shares")

    // The helper runs as root and mounts on somebody else's behalf, so it
    // composes the same path against their home. The two must agree exactly, or
    // a drive opened with the helper reads a different Linux environment from
    // one opened without it -- different versions the moment either updates.
    let release = EngineEnvironment.engineHome(inHome: "/Users/someone", named: "Lukotta")
    expect(release.path != home.path, "a beta and a release are two directories, not one")

    expect(
        EngineEnvironment.alpineDirectory.path.hasPrefix(EngineEnvironment.engineHome.path),
        "the Linux environment lives inside it")
    expect(
        EngineConfig.path.hasPrefix(EngineEnvironment.engineHome.path),
        "so does the engine's configuration, which is this app's own copy")
    expect(
        Housekeeping.EngineLogs.directory.path.hasPrefix(EngineEnvironment.engineHome.path),
        "and its logs, so a Mac running anylinuxfs on its own keeps its own")

    // Every run of the engine carries it. One that does not looks in the shared
    // home instead, which is a different image and may be another program's.
    let environment = EngineEnvironment.environmentForEngine(base: ["PATH": "/usr/bin"])
    expect(
        environment[EngineEnvironment.homeVariable] == EngineEnvironment.engineHome.path,
        "every run of the engine is told where its directory is")
    expect(environment["PATH"] == "/usr/bin", "and keeps the rest of the environment it was given")
}

group("anEngineThatServesNothingIsNotLeftRunning") {
    // The engine runs one instance at a time and refuses to start while another
    // is there. A mount that failed, or one whose eject did not take its
    // machine with it, therefore stops the next drive opening at all -- and
    // what somebody sees is being told the engine is busy immediately after
    // typing a passphrase wrong.
    let serving = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        127.0.0.1:/Elements on /Users/u/Volumes/Elements (nfs, nodev, nosuid, mounted by u)
        """
    expect(
        EngineProcesses.tidyWhatServesNothing(mountTable: serving) == 0,
        "with a drive still served, nothing is taken down")

    let nothing = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        /dev/disk4s1 on /Volumes/WINDOWS (ntfs, local, nodev, nosuid, read-only)
        """
    // Nothing of this app's engine is running under the test binary, so what is
    // asserted is the judgment rather than the killing: no NFS mount anywhere
    // means nothing the engine runs is serving anything.
    expect(
        EngineProcesses.tidyWhatServesNothing(mountTable: nothing) == 0,
        "and with no engine running there is nothing to take down either")
    expect(
        !MountTableEntry.all(in: nothing).contains(where: \.isNFS),
        "a mount table with no NFS in it is the evidence that decides it")
    expect(
        MountTableEntry.all(in: serving).contains(where: \.isNFS),
        "and one with an NFS mount is the evidence against")
}

group("aDriveMacOSAlreadyHasCanBeTakenBackFromIt") {
    // macOS mounts NTFS and exFAT itself, and the engine will not touch a disk
    // the host already has. Until now that was a sentence on a failure screen
    // and nothing else. The rule has to be identified by name: the sentence is
    // translated, so matching words in it works in English and nowhere else.
    let transcript = "Error: /dev/disk4s1 is already mounted at /Volumes/WINDOWS"
    expect(
        Diagnosis.rule(for: transcript)?.name == "already-mounted",
        "the engine's complaint is recognised as the drive being held by macOS")

    // Which of the host's mounts belong to the disk being opened. A container
    // is one row in the list and several devices in the mount table, so a
    // sibling partition of the same disk counts and another disk does not.
    let table = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        /dev/disk4s1 on /Volumes/WINDOWS (ntfs, local, nodev, nosuid, read-only)
        /dev/disk4s2 on /Volumes/DATA (exfat, local, nodev, nosuid)
        /dev/disk5s1 on /Volumes/OTHER (ntfs, local, read-only)
        """
    let disk = DriveScanner.wholeDisk(of: "disk4s1")
    let taken = MountTableEntry.all(in: table).filter {
        guard $0.source.hasPrefix("/dev/") else { return false }
        let identifier = ($0.source as NSString).lastPathComponent
        return identifier == "disk4s1" || DriveScanner.wholeDisk(of: identifier) == disk
    }
    expect(
        taken.map(\.mountPoint) == ["/Volumes/WINDOWS", "/Volumes/DATA"],
        "every volume of that disk is taken back, and nothing from another")
    expect(
        !taken.contains { $0.mountPoint == "/" },
        "and never the volume this Mac is running from")
}

group("theEnginesOwnLogsDoNotPileUpForEver") {
    // Three files a mount, nineteen kilobytes, written into ~/Library/Logs by
    // the engine itself and never rotated. They cannot be recognised by name:
    // a Mac running anylinuxfs on its own writes files called exactly the same,
    // and deleting those would be reaching into somebody else's work.
    let fm = FileManager.default
    let logs = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("logs-check-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: logs)
        UserDefaults.standard.removeObject(forKey: Housekeeping.EngineLogs.key)
    }
    UserDefaults.standard.removeObject(forKey: Housekeeping.EngineLogs.key)

    func write(_ name: String, agedByDays days: Double) {
        let file = logs.appendingPathComponent(name)
        try? "log".write(to: file, atomically: true, encoding: .utf8)
        try? fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 24 * 60 * 60)],
            ofItemAtPath: file.path)
    }

    // Somebody else's, already there before this app ran.
    write("anylinuxfs-THEIRS01.log", agedByDays: 30)
    let before = Housekeeping.EngineLogs.present(in: logs)
    expect(before.count == 1, "what is already there is seen")

    // What a mount of ours writes.
    write("anylinuxfs-OURS0001.log", agedByDays: 30)
    write("anylinuxfs_kernel-OURS0001.log", agedByDays: 30)
    write("anylinuxfs_nethelper-OURS0001.log", agedByDays: 30)
    write("anylinuxfs-OURS0002.log", agedByDays: 1)
    write("something-else.txt", agedByDays: 30)
    let claimed = Housekeeping.EngineLogs.claimAppeared(since: before, in: logs)
    expect(claimed.count == 4, "the four the engine wrote are claimed")
    expect(
        !claimed.contains("something-else.txt"),
        "and nothing that is not one of the engine's logs")

    let removed = Housekeeping.EngineLogs.removeOld(in: logs)
    expect(removed == 3, "ours, once old, are taken away")
    expect(
        fm.fileExists(atPath: logs.appendingPathComponent("anylinuxfs-THEIRS01.log").path),
        "and a log this app never wrote is left alone, however old")
    expect(
        fm.fileExists(atPath: logs.appendingPathComponent("anylinuxfs-OURS0002.log").path),
        "as is one recent enough to be wanted for a bug report")
    expect(
        UserDefaults.standard.stringArray(forKey: Housekeeping.EngineLogs.key) == [
            "anylinuxfs-OURS0002.log"
        ],
        "and the list shrinks to what is still there, rather than growing for ever")
}

group("aRecoveryKeyIsCheckedBeforeTheDriveIsAskedAboutIt") {
    // Every case the shell validator carried, now that the logic is Swift.
    // A recovery key is eight groups of six digits, each group a 16-bit value
    // multiplied by eleven -- so a mistyped one can be named exactly here
    // rather than coming back from cryptsetup half a minute later as a plain
    // refusal.
    func value(_ raw: String) -> String? {
        guard case .success(let out) = Credential.normalise(raw) else { return nil }
        return out
    }
    func refusal(_ raw: String) -> String? {
        guard case .failure(.credentialRejected(let why)) = Credential.normalise(raw) else {
            return nil
        }
        return why
    }

    let key = "110011-220022-330033-440044-550055-660066-700007-711711"
    expect(value(key) == key, "a valid key comes back as it was")
    expect(
        value("110011220022330033440044550055660066700007711711") == key,
        "one typed without separators is put into groups")
    expect(
        value("110011 220022 330033 440044 550055 660066 700007 711711") == key,
        "and so is one typed with spaces")

    expect(
        refusal("110011-220022-330033-440044-550055-660066-700007-711712") != nil,
        "a group that fails the checksum is refused")
    expect(
        refusal("110011-220022-330033-440044-550055-660066-700007-711712")?.contains("8") == true,
        "and the refusal says which group, since that is the one to retype")
    expect(
        refusal("999999-220022-330033-440044-550055-660066-700007-711711") != nil,
        "a group above what sixteen bits can hold is refused")
    expect(
        refusal("110011-220022-330033-440044-550055-660066-700007-71171")?.contains("47") == true,
        "a key of the wrong length says how many digits were typed")

    // A password is not a key, and is never touched: spaces and punctuation
    // are all significant in one.
    for password in [
        "Correct Horse Battery!", "12000008", "p@ss-word 42", "ÜmlautPass",
        "110011-220022-330033-440044-550055-660066-700007-AAAAAA",
    ] {
        expect(value(password) == password, "a password passes through exactly: \(password)")
    }

    expect(refusal("") != nil, "nothing typed is refused")
    expect(
        refusal("")?.contains("48") == true,
        "with the sentence that says what may be typed instead")

    // The hint while typing, which must not nag at a password.
    expect(Credential.hint(for: "hunter2") == nil, "a password gets no hint")
    expect(
        Credential.hint(for: "110011-220022-330033-440044")?.contains("24") == true,
        "a part-typed key counts what is there so far")
}

group("everyMovingPartStatesItsOwnVersion") {
    // The app is not one program, and "which version" has more than one answer.
    // A part that is installed rather than carried -- the Linux environment in
    // the home directory, the daemon launchd keeps running across an update --
    // can be older than the app in front of it, and both have been.
    let shipped = Component(id: "guest_rootfs", shipped: "1.5.1", installed: "1.5.1")
    expect(!shipped.isStale, "what is installed matching what ships is not stale")
    let old = Component(id: "guest_rootfs", shipped: "1.6.0", installed: "1.5.1")
    expect(old.isStale, "an older one installed is")
    expect(
        old.line == "guest_rootfs 1.6.0 (installed: 1.5.1)",
        "and the line says both, rather than only the one that is easy to read")

    // Evidence or nothing. A part this app cannot read a version for is a
    // question, and a question reported as agreement is how the environment
    // went unrefreshed for every release so far.
    expect(
        !Component(id: "helper", shipped: "412", installed: nil).isStale,
        "a part that did not answer is not called stale")
    expect(
        !Component(id: "engine", shipped: nil, installed: "0.19.0").isStale,
        "nor one this app states no version for")
    expect(
        Component(id: "helper", shipped: nil, installed: "301").line
            == "helper installed 301, this app states none",
        "which the line says outright")

    // The summary is what goes into a bug report, and the disagreement has to
    // be in it: a reader scanning a dozen lines will not diff them by eye.
    let summary = Components.summary([
        Component(id: "app", shipped: "1.4.0 (build 412)"),
        old,
        Component(id: "helper", shipped: "412", installed: "301"),
    ])
    expect(summary.contains("guest_rootfs 1.6.0 (installed: 1.5.1)"), "the summary lists the parts")
    expect(
        summary.contains("installed and shipped disagree: guest_rootfs, helper"),
        "and names every one that disagrees")
    expect(
        Components.stale([shipped, old]).map(\.id) == ["guest_rootfs"],
        "and the same judgment is available on its own")

    // The wiring, not only the arithmetic: the version of the environment out
    // there is read from the environment out there. Asserted against a
    // directory made for it, because the one on this Mac is whatever the last
    // run left and would pass while reading nothing.
    let fm = FileManager.default
    let guest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("parts-check-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(
        at: guest.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: guest) }
    try? "9.9.9-fixture".write(
        to: guest.appendingPathComponent("rootfs.ver"), atomically: true, encoding: .utf8)
    let installed = Components.all(guestDirectory: guest).first { $0.id == "guest_rootfs" }
    expect(
        installed?.installed == "9.9.9-fixture",
        "the environment's own version is read from where it is installed")

    // The script is generated rather than shipped, so it states its version in
    // its own text or nowhere.
    expect(
        MountScript.build(sampleInputs()).contains(
            "# lukotta mount script v\(Components.mountScriptVersion)"),
        "the script says which version of itself wrote the log")
}

group("anUpdatedLinuxEnvironmentActuallyArrives") {
    // The environment was unpacked once, on the first run, and never again --
    // so an update that changed the guest reached nobody who already had the
    // app. The version file was written by the build, shipped in the bundle,
    // and read by nothing.
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("guest-check-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    defer { try? fm.removeItem(at: base) }
    try? fm.createDirectory(
        at: base.appendingPathComponent("rootfs"), withIntermediateDirectories: true)

    func setVersion(_ text: String?) {
        let file = base.appendingPathComponent("rootfs.ver")
        try? fm.removeItem(at: file)
        if let text { try? text.write(to: file, atomically: true, encoding: .utf8) }
    }

    setVersion("1.5.1")
    expect(EngineEnvironment.isReady(in: base), "an unpacked environment is ready")
    expect(
        !EngineEnvironment.needsRefresh(in: base, shipped: "1.5.1"),
        "the same version is left alone")
    expect(
        EngineEnvironment.needsRefresh(in: base, shipped: "1.6.0"),
        "a different one is replaced")

    // The environment lives in this app's own directory, which nothing else on
    // the Mac writes to -- so there is no question of whose it is, and no
    // sentence anybody has to read about another program. What is left of that
    // problem is the one copy installed before the directory existed: it is
    // moved across, in place, and only when it is unmistakably this app's own
    // work.
    let shared = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("shared-home-\(UUID().uuidString)", isDirectory: true)
    let mine = shared.deletingLastPathComponent()
        .appendingPathComponent("own-home-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fm.removeItem(at: shared)
        try? fm.removeItem(at: mine)
    }
    try? fm.createDirectory(
        at: shared.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
    try? "1.5.1".write(
        to: shared.appendingPathComponent("rootfs.ver"), atomically: true, encoding: .utf8)

    expect(
        !EngineEnvironment.adoptWhatWasLeftInTheSharedHome(
            from: shared, into: mine, mountTable: ""),
        "an environment another program unpacked is left where it is")
    for marker in ["rootfs.count", "removed-packages.txt"] {
        try? "1".write(
            to: shared.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    }
    expect(
        EngineEnvironment.adoptWhatWasLeftInTheSharedHome(
            from: shared, into: mine, mountTable: ""),
        "and one this app unpacked itself is moved into its own directory")
    expect(EngineEnvironment.isReady(in: mine), "so it is ready without unpacking anything again")
    expect(!fm.fileExists(atPath: shared.path), "and nothing of it is left in the shared one")
    expect(
        !EngineEnvironment.adoptWhatWasLeftInTheSharedHome(
            from: shared, into: mine, mountTable: ""),
        "a second run finds nothing to move and says so")
    // Never out from under a machine that is serving a drive from it.
    try? fm.createDirectory(
        at: shared.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
    for marker in ["rootfs.count", "removed-packages.txt", "rootfs.ver"] {
        try? "1".write(
            to: shared.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    }
    try? fm.removeItem(at: mine)
    expect(
        !EngineEnvironment.adoptWhatWasLeftInTheSharedHome(
            from: shared, into: mine,
            mountTable: "disk4s1.local:/mnt/X on /Users/u/Volumes/X (nfs, nodev, nosuid)"),
        "and never while a drive is being served from it")

    // Evidence or nothing: this replaces a working environment.
    setVersion(nil)
    expect(
        !EngineEnvironment.needsRefresh(in: base, shipped: "1.6.0"),
        "an environment from before the version file is left alone")
    setVersion("1.5.1")
    expect(
        !EngineEnvironment.needsRefresh(in: base, shipped: nil),
        "and so is one this app cannot state a version for")

    // Nothing unpacked at all is a first run, not a refresh.
    try? fm.removeItem(at: base.appendingPathComponent("rootfs"))
    expect(
        !EngineEnvironment.needsRefresh(in: base, shipped: "1.6.0"),
        "with nothing unpacked there is nothing to refresh")
}

group("nothingIsLeftLyingAboutOnSomebodysMac") {
    // The three rules: only what this app made, only when it is finished with,
    // and never anything in use.
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("housekeeping-check-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    func make(_ name: String, agedBy seconds: TimeInterval) -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: dir.path)
        return dir
    }
    let old = make("\(Workspace.prefix)\(UUID().uuidString)", agedBy: 3600)
    let fresh = make("\(Workspace.prefix)\(UUID().uuidString)", agedBy: 5)
    let theirs = make("SomeoneElse-\(UUID().uuidString)", agedBy: 3600)
    // A pre-release's scratch directory, in the same temporary directory: as
    // old as the first, and not this copy of the app's to remove.
    let otherChannel = make("Lukotta-com.lukotta.beta-\(UUID().uuidString)", agedBy: 3600)

    let removed = Housekeeping.removeFinishedWorkspaces(now: Date(), in: base)
    expect(removed == 1, "one workspace was finished with")
    expect(!FileManager.default.fileExists(atPath: old.path), "the old one is gone")
    expect(
        FileManager.default.fileExists(atPath: fresh.path),
        "a mount that may still be running is left alone")
    expect(
        FileManager.default.fileExists(atPath: theirs.path),
        "and nothing that is not this app's is touched, however old")
    expect(
        FileManager.default.fileExists(atPath: otherChannel.path),
        "including another channel of this same app")

    // A mount point with something mounted on it is never removed, however
    // empty the directory looks from here.
    let home = base.appendingPathComponent("home", isDirectory: true)
    let volumes = home.appendingPathComponent("Volumes", isDirectory: true)
    let busy = volumes.appendingPathComponent("BUSY", isDirectory: true)
    let idle = volumes.appendingPathComponent("IDLE", isDirectory: true)
    try? FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: idle, withIntermediateDirectories: true)
    let table = "x.local:/mnt/BUSY on \(busy.path) (nfs, nodev)"
    let points = Housekeeping.removeEmptyMountPoints(in: table, home: home)
    expect(points == 1, "the empty one is taken away")
    expect(FileManager.default.fileExists(atPath: busy.path), "and the mounted one is not")
}

group("howManyDrivesThisMacCanServeAtOnce") {
    // Every open drive is a virtual machine serving NFS, and NFS has one port,
    // so each one needs a loopback address of its own. That, and nothing about
    // memory or processors, is what limits how many can be open.
    let addresses = Capacity.addresses()
    expect(addresses.contains("127.0.0.1"), "the loopback interface is read from the machine")
    expect(addresses.count >= 3, "a Mac has at least three loopback addresses")

    // The limit is what the machine has, never a number written down here: the
    // helper adds addresses, and a Mac where it never arrived has three.
    //
    // Counted over the addresses a drive can be served on, which is the IPv4
    // ones: lo0 also carries ::1 and fe80::1, and counting those said this Mac
    // could open two more drives than it had anywhere to put -- so the last one
    // failed for an address while the app still showed room.
    let serving = Capacity.addressesForServing()
    expect(
        serving.allSatisfy { !$0.contains(":") },
        "the addresses counted are the ones the engine exports over")
    expect(serving.count <= addresses.count, "which is never more than the interface carries")
    expect(Capacity.now(mounts: 0).limitCount == serving.count, "the limit is what is there")
    // Adding and releasing have to cover the same range, or an uninstall leaves
    // addresses on the interface that nothing will ever take away.
    expect(
        Capacity.lastLoopbackAddress >= 2 + Capacity.wanted,
        "the address range reaches at least as far as the ceiling needs")
    expect(Capacity.now(mounts: 2).openCount == 2, "and what is open is what is mounted")
    expect(Capacity.hasRoom(limitCount: 12, openCount: 11), "room below the limit")
    expect(!Capacity.hasRoom(limitCount: 12, openCount: 12), "and none at it")
    expect(!Capacity.hasRoom(limitCount: 3, openCount: 4), "nor past it, however that happened")
    expect(Capacity.wanted == 12, "a dozen is what the helper is asked to prepare")

    // A machine that answers nothing still has to be usable.
    expect(Capacity.now(mounts: 0).limitCount >= 1, "the limit is never zero")
    expect(Capacity.addresses(of: "nx99").isEmpty, "an interface that is not there has none")
}

group("theListKeepsTheOrderThingsArrivedIn") {
    // Rows used to come back in whatever order a scan and two dictionaries
    // produced, so opening a second image moved the first one and a drive
    // plugged in third arrived in the middle of the list.
    func drive(_ name: String) -> Drive {
        Drive(
            id: name, devicePath: "/dev/" + name, name: name, sizeBytes: 1,
            connection: "USB", kind: .linux, uuid: "uuid-" + name)
    }
    let key: (Drive) -> String = { $0.uuid }
    var order = DriveOrder()

    let first = order.apply([drive("a"), drive("b")], key: key)
    expect(first.map(\.id) == ["a", "b"], "the first list is the order it came in")

    // The same two, as a scan might hand them back, plus a third.
    let second = order.apply([drive("b"), drive("c"), drive("a")], key: key)
    expect(
        second.map(\.id) == ["a", "b", "c"],
        "what was there stays where it was, and the new one goes to the bottom")

    let unplugged = order.apply([drive("a"), drive("c")], key: key)
    expect(unplugged.map(\.id) == ["a", "c"], "one that has gone leaves a closed gap")

    let backAgain = order.apply([drive("a"), drive("c"), drive("b")], key: key)
    expect(
        backAgain.map(\.id) == ["a", "c", "b"],
        "and comes back at the bottom, a drive plugged in again being a drive arriving")

    let twice = order.apply([drive("a"), drive("a")], key: key)
    expect(twice.count == 1, "the same thing seen twice is one row")

    // Dragged into an order of somebody's own, which outlives the rows it was
    // made from: what they arranged is what they see next time.
    order.adopt(["uuid-c", "uuid-a", "uuid-b"])
    let arranged = order.apply([drive("a"), drive("b"), drive("c")], key: key)
    expect(arranged.map(\.id) == ["c", "a", "b"], "an order arranged by hand is kept")
    var later = DriveOrder(arrangement: order.arrangement)
    let afterRestart = later.apply([drive("b"), drive("a"), drive("c")], key: key)
    expect(afterRestart.map(\.id) == ["c", "a", "b"], "and is still there at the next launch")
    let andNew = later.apply([drive("a"), drive("b"), drive("c"), drive("d")], key: key)
    expect(andNew.map(\.id) == ["c", "a", "b", "d"], "with anything new below it")
    // A place somebody gave a row is kept for it while the drive is away,
    // which is the difference between an arrangement and an order things
    // happened to arrive in.
    let oneAway = later.apply([drive("a"), drive("c"), drive("d")], key: key)
    expect(oneAway.map(\.id) == ["c", "a", "d"], "an arranged row keeps its place while unplugged")
    let backInPlace = later.apply([drive("d"), drive("b"), drive("a"), drive("c")], key: key)
    expect(backInPlace.map(\.id) == ["c", "a", "b", "d"], "and returns to it")
}

group("onlyWhatThisAppAttachedIsPutBack") {
    // A container left attached by a crash is put back at the next launch.
    // Read as "every attached image nothing is mounted from", that swept up
    // other programs' work: attach a raw image in Terminal, open this app, and
    // the image was detached by an app that had never touched it.
    expect(
        DiskImage.strayAttachments(ours: []).isEmpty,
        "with nothing of ours attached, nothing is put back")
}

group("anAttachedImageIsNotADrive") {
    // A disk image is a file, opened by name from the File menu and listed on
    // the app's own screen. The sheet lists the drives attached to this Mac,
    // and no image is one -- not a leftover, not another program's, and not
    // one this app opened itself.
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk8",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk8s1", "Content": "Linux Filesystem",
                        "Size": NSNumber(value: 2_000_000_000),
                    ]
                ],
            ]
        ]
    ]
    let asImage: (String) -> [String: Any] = { _ in
        ["BusProtocol": "Disk Image", "VirtualOrPhysical": "Virtual", "Internal": false]
    }
    expect(
        DriveSurvey.survey(list: plist, info: asImage, mountTable: "", openable: []).isEmpty,
        "an attached image is not a drive")

    let opened = Drive(
        id: "disk8s1", devicePath: "/dev/disk8s1", name: "backup.img", sizeBytes: 2_000_000_000,
        connection: "Disk Image", kind: .linux, uuid: "/Users/someone/backup.img")
    expect(
        DriveSurvey.survey(list: plist, info: asImage, mountTable: "", openable: [opened]).isEmpty,
        "nor is one this app opened itself")
}

group("theHelperSaysWhichBuildItIs") {
    // launchd keeps a registered daemon running across an app update, and the
    // helper is what builds the mount -- so a fixed app went on behaving as the
    // broken one had, with nothing to say so. The app asks the helper what it
    // is and registers it again when the answer does not match, which needs
    // both halves to exist.
    let helper =
        (try? String(contentsOfFile: "sources/LukottaHelper/main.swift", encoding: .utf8)) ?? ""
    let client =
        (try? String(contentsOfFile: "sources/Lukotta/HelperClient.swift", encoding: .utf8)) ?? ""
    expect(helper.contains("func helperVersion("), "the helper can say which build it is")
    expect(client.contains("func replaceIfStale()"), "and the app asks")
    expect(
        client.contains("try? self.service.unregister()")
            && client.contains("try? self.service.register()"),
        "and registers it again when the answer does not match")

    let model =
        (try? String(contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    expect(model.contains("helper.replaceIfStale()"), "on the way in, before anything is mounted")
}

group("aDaemonThatIsNotThisBuildsNeverServesAMount") {
    // The fault this exists to make impossible: launchd keeps the running
    // daemon across an application update, the daemon is what builds the
    // mount, so a fixed application mounted exactly as the broken one had and
    // nothing said so. An NTFS fix shipped, installed, and changed nothing.
    //
    // The contract number cannot be the whole answer -- it is raised by hand,
    // and the note against 4 in HelperProtocol records it shipping with the
    // wrong meaning. So the binaries are compared, which needs nothing of the
    // daemon and works while it is dead.
    let dir = NSTemporaryDirectory() + "helper-staleness-\(UInt32.random(in: 0..<999999))"
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let installed = dir + "/installed", bundled = dir + "/bundled"

    FileManager.default.createFile(atPath: installed, contents: Data("same".utf8))
    FileManager.default.createFile(atPath: bundled, contents: Data("same".utf8))
    expect(
        HelperInfo.installedToolIsCurrent(installed: installed, bundled: bundled),
        "the same binary in both places is current")

    try? Data("older".utf8).write(to: URL(fileURLWithPath: installed))
    expect(
        !HelperInfo.installedToolIsCurrent(installed: installed, bundled: bundled),
        "a daemon that differs from the one the bundle carries is stale")

    try? FileManager.default.removeItem(atPath: installed)
    expect(
        !HelperInfo.installedToolIsCurrent(installed: installed, bundled: bundled),
        "and one that is not there at all is stale, not fine")

    // Unreadable answers the same as wrong. Both lead to replacing it, and a
    // check that cannot prove currency must never report it.
    expect(
        !HelperInfo.installedToolIsCurrent(
            installed: bundled, bundled: dir + "/never-written"),
        "nothing to compare against is stale too")

    let client =
        (try? String(contentsOfFile: "sources/Lukotta/HelperClient.swift", encoding: .utf8)) ?? ""
    expect(
        client.contains("var installedToolIsStale: Bool"),
        "the client can tell without asking the daemon anything")
    expect(
        client.contains("theirs < HelperInfo.contract || stale"),
        "and either signal is enough to replace it")
    expect(
        !client.contains("This version needs setting up again. It takes one password."),
        "a daemon that will not replace itself is not reported at somebody")

    expect(
        !client.contains("self.install()"),
        "nothing on the launch path can raise an administrator panel")

    let model =
        (try? String(contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    expect(
        model.contains("if helper.installedToolIsStale {"),
        "the mount checks before it goes near the daemon")
    expect(
        model.contains("let mountThroughHelper = helper.isReady && !helper.installedToolIsStale"),
        "and a stale daemon never serves the mount")

    // One authorisation per installation, at the first mount, and never again.
    // replaceIfStale() runs on the way in, so an install() reachable from there
    // is a password panel raised by starting the application -- which happened,
    // and shipped, and is why this is checked rather than remembered.
    let installSites = model.components(separatedBy: "helper.install()").count - 1
    expect(installSites == 1, "the application asks to be set up in exactly one place")
    let beforeInstall = model.components(separatedBy: "helper.install()")[0]
    expect(
        beforeInstall.hasSuffix("if case .notInstalled = helper.state {\n            "),
        "and that place is the first mount, where somebody has asked for a drive")

    // And when it does ask, it asks for the route that cannot go stale.
    // SMJobBless puts the daemon in /Library, where an application update
    // cannot reach it; SMAppService runs it out of the bundle, so replacing the
    // bundle replaces the daemon. The released application has used the second
    // across four updates without a password; the beta used the first and
    // stranded a daemon that could neither serve a mount nor be replaced.
    let registerAt = client.range(of: "try self.service.register()")
    let blessAt = client.range(of: "HelperClient.blessWithAuthorisation()", options: .backwards)
    expect(registerAt != nil && blessAt != nil, "both routes are still there")
    if let r = registerAt, let b = blessAt {
        expect(
            r.lowerBound < b.lowerBound,
            "registering is tried first; the password is the fallback")
    }
    expect(
        client.contains(
            "FileManager.default.fileExists(atPath: HelperInfo.installedJobPath)\n                ? false : HelperClient.blessWithAuthorisation()"
        ),
        "a daemon already installed the old way is never blessed a second time")
}

group("anUnansweredEngineNeverClearsAMount") {
    // The fault that ended a copy. Under heavy disk load the engine's own
    // `status` call does not return. `current()` reported that as an empty
    // list -- the same thing it reports when the engine answers and nothing is
    // mounted -- so `stale()` read every live mount as abandoned and the
    // application force-unmounted the drive being copied to and told the
    // microVM to quit. Straight out of the engine log:
    //
    //     macOS: Share /Users/someone/Volumes/FEDORAROOT was unmounted
    //     Linux: Received command: 'Quit'
    //     macOS: Removing mount point /Users/someone/Volumes/FEDORAROOT
    //
    // "Could not ask" and "asked, and the answer was none" are opposite facts.
    // Only the second may unmount anything.
    let engineSays = """
        lvm:fedoravg:disk5s1:root on /Users/someone/Volumes/FEDORAROOT (btrfs) VM[cpus: 2]
        """
    let table = """
        lvm-fedoravg.local:/mnt/FEDORAROOT on /Users/someone/Volumes/FEDORAROOT (nfs, mounted by someone)
        other.local:/mnt/GONE on /Users/someone/Volumes/GONE (nfs, mounted by someone)
        """

    // Asked, and answered: the one the engine does not name is genuinely stale.
    let answered = EngineStatus.parse(engineSays).map(\.mountPoint)
    let staleGivenAnswer = EngineStatus.engineMountPoints(in: table)
        .filter { point in
            !answered.contains(point) && !answered.contains { point.hasPrefix($0 + "/") }
        }
    expect(
        staleGivenAnswer == ["/Users/someone/Volumes/GONE"],
        "a mount the engine does not report, when it did report, is stale")

    // Parsing an empty answer yields nothing, which is what made the two
    // indistinguishable before.
    expect(EngineStatus.parse("").isEmpty, "an empty answer parses to no mounts")

    // The source now separates them, and nothing destructive runs without one.
    let status =
        (try? String(contentsOfFile: "sources/LukottaCore/EngineStatus.swift", encoding: .utf8))
        ?? ""
    expect(
        status.contains("public static func currentIfAnswered() -> [EngineMount]?"),
        "there is a way to tell an unanswered question from an empty answer")
    expect(
        status.contains("case .couldNotAsk: return nil"),
        "an engine that could not be asked answers nothing, not none")
    // Three ways to fail to get an answer, and all three must be nil. The first
    // version of this fix caught only one of them: a `status` that ran and
    // exited non-zero printing nothing parses to an empty list, which is
    // indistinguishable from an engine serving no drives -- and that is the
    // reading that force-unmounts them.
    expect(
        status.contains("case .finished(let output) where output.status == 0"),
        "only a run that succeeded counts as an answer")
    expect(
        status.contains("case .finished: return nil"),
        "a run that failed is not an answer of none")
    expect(
        status.contains("case .silent: return nil"),
        "and neither is one still going when the deadline passed")
    expect(
        status.contains("[\"status\"], timeout: 10"),
        "and the question is bounded, so a wedged engine cannot hang the asker")
    expect(
        status.contains("guard let answered = currentIfAnswered() else { return [] }"),
        "stale() clears nothing when the engine was never reached")

    let model =
        (try? String(contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    expect(
        model.contains("guard let answered = EngineStatus.currentIfAnswered() else {"),
        "and waking does not drop mounts on an unanswered question either")

    // The condition itself, at run time: point the engine somewhere that does
    // not exist and it genuinely cannot be asked. Whatever this Mac happens to
    // have mounted, nothing may be reported stale -- because the answer that
    // would justify unmounting was never obtained. Before the fix this returned
    // every engine mount on the machine, and the caller unmounted them.
    let realEngine = EnginePaths.engineRoot

    // An engine that runs and fails, which is the case the first version of
    // this fix missed: the process starts, exits non-zero, prints nothing, and
    // an empty output parses to an empty list of mounts.
    let fakeRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
            "failing-engine-\(UInt32.random(in: 0..<999999))", isDirectory: true)
    let fakeBin = fakeRoot.appendingPathComponent("anylinuxfs/bin", isDirectory: true)
    try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fake = fakeBin.appendingPathComponent("anylinuxfs")
    try? "#!/bin/sh\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    defer { try? FileManager.default.removeItem(at: fakeRoot) }

    EnginePaths.useEngine(at: fakeRoot)
    expect(
        EngineStatus.currentIfAnswered() == nil,
        "an engine that runs and fails has not answered")
    expect(
        EngineStatus.stale().isEmpty,
        "so nothing is stale, whatever this Mac has mounted")

    EnginePaths.useEngine(at: URL(fileURLWithPath: "/nonexistent-engine-for-this-test"))
    expect(
        EngineStatus.currentIfAnswered() == nil,
        "an engine that is not there cannot be asked")
    // The two answers the old code could not tell apart, side by side. current()
    // still says "no mounts", because that is all a list can say; the fix is
    // that the destructive path no longer asks it.
    expect(
        EngineStatus.current().isEmpty,
        "the list form still reports nothing -- which is why it must not be the one consulted")
    expect(
        EngineStatus.stale().isEmpty,
        "and so nothing is stale, whatever is mounted on this machine")
    EnginePaths.useEngine(at: realEngine)
}

group("aStalledMountIsNoticedAndSaidOnce") {
    // The fault: a copy froze at 23:22 and the window looked identical at
    // 23:37. The mount stays in the table throughout, so "is it mounted" is
    // useless; what stops is answers. Reproduced by duty-cycling the guest --
    // mostly stopped, briefly running -- which leaves the mount up while a
    // stat of it stops returning, exactly what was seen.
    var watch = StallWatch()

    // One unanswered probe is a hiccup, not a stall.
    expect(watch.record(answered: false) == .quiet, "one miss says nothing")
    expect(watch.record(answered: false) == .quiet, "two misses say nothing")
    expect(watch.record(answered: false) == .stalled, "three in a row is a stall")
    expect(watch.isStalled, "and it knows it is in one")

    // Said once, however long it lasts.
    expect(watch.record(answered: false) == .quiet, "a stall is announced once")
    expect(watch.record(answered: false) == .quiet, "and not again")

    // Coming back is worth one sentence too.
    expect(watch.record(answered: true) == .recovered, "recovery is said")
    expect(!watch.isStalled, "and the stall is over")
    expect(watch.record(answered: true) == .quiet, "but only once")

    // A miss that does not reach the count leaves nothing behind.
    var flaky = StallWatch()
    expect(flaky.record(answered: false) == .quiet, "")
    expect(flaky.record(answered: true) == .quiet, "a recovered hiccup says nothing at all")
    expect(flaky.record(answered: false) == .quiet, "and the count started again")
    expect(flaky.record(answered: false) == .quiet, "")
    expect(flaky.record(answered: false) == .stalled, "three fresh misses still stall")

    // The numbers themselves: three probes at twenty seconds is a little over a
    // minute of silence before anybody is told, and each probe waits five
    // seconds, which is thousands of times a healthy loopback answer.
    expect(StallWatch.strikes == 3, "three strikes")
    expect(StallWatch.interval == 20, "twenty seconds apart")
    expect(StallWatch.probeDeadline == 5, "five seconds to answer")
}

group("aMountPointLeftWithFilesInItIsReported") {
    // The defect this exists for, reproduced twice on real mounts: the guest
    // stops answering for longer than deadtimeout=45, macOS drops the mount,
    // and the directory it was mounted on stays behind as an ordinary
    // directory on the startup disk. A copy still running writes into it and
    // succeeds. 115 of 150 files landed there, byte-correct and on the wrong
    // disk, with Finder reporting the copy finished.
    //
    // Empty leftovers are litter and are removed. These are not: removing one
    // would destroy the only copy of what is in it. They are reported instead.
    let base = URL(
        fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("stranded-\(UInt32.random(in: 0..<999999))", isDirectory: true)
    let volumes = base.appendingPathComponent("Volumes", isDirectory: true)
    let empty = volumes.appendingPathComponent("EMPTY", isDirectory: true)
    let full = volumes.appendingPathComponent("FULL", isDirectory: true)
    let mountedOn = volumes.appendingPathComponent("LIVE", isDirectory: true)
    for d in [empty, full, mountedOn] {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: base) }
    FileManager.default.createFile(atPath: full.appendingPathComponent("a").path, contents: Data())
    FileManager.default.createFile(atPath: full.appendingPathComponent("b").path, contents: Data())
    // A live mount must never be reported, however full it is.
    FileManager.default.createFile(
        atPath: mountedOn.appendingPathComponent("c").path, contents: Data())
    let table = "server:/export on \(mountedOn.path) (nfs, nodev, nosuid, mounted by someone)\n"

    let stranded = Housekeeping.strandedMountPoints(in: table, home: base)
    expect(stranded.count == 1, "only the unmounted one holding files is reported")
    expect(stranded.first?.path == full.path, "and it is the right one")
    expect(stranded.first?.files == 2, "with how much is in it")

    let removed = Housekeeping.removeEmptyMountPoints(in: table, home: base)
    expect(removed == 1, "the empty one is swept")
    expect(
        FileManager.default.fileExists(atPath: full.path),
        "the one with files in it is never removed -- that would be the only copy")
    expect(
        FileManager.default.fileExists(atPath: mountedOn.path),
        "and a live mount is left alone")
}

group("theMountIsSoftAndTheCodeSaysSo") {
    // The engine merges its own NFS defaults over whatever the application
    // passes, and on macOS those include "soft", timeo=100 and retrans=3. So
    // every mount is soft with a ten-second timeout, which is precisely the
    // configuration the old comment here called unacceptable -- while claiming
    // this was a hard mount because it had not asked for a soft one.
    //
    // Read off a real mount before writing this down:
    //   mount -t nfs -o deadtimeout=45,intr,...,retrans=3,...,soft,timeo=100,...
    //
    // Checked as text because the fact lives in a comment, and a comment that
    // is wrong about safety is worse than no comment: the previous one talked
    // an audit out of a finding that was correct.
    let script =
        (try? String(contentsOfFile: "sources/LukottaCore/MountScript.swift", encoding: .utf8))
        ?? ""
    expect(
        !script.contains("This is a hard mount"),
        "the code does not claim a hard mount it does not have")
    expect(
        script.contains("soft, intr, timeo=100, retrans=3, deadtimeout=45"),
        "it records what the engine actually merges in")
    expect(
        script.contains("panics the kernel once"),
        "and why soft cannot simply be removed")
}

group("aReadOnlyMountAsksForItInOneFlag") {
    // --ignore-permissions and a read-only export are the same job to the
    // engine -- taking charge of the NFS export -- so it refuses the two
    // together and every read-only mount of a real drive failed before the
    // machine started. A read-only mount asks for both in the one flag.
    let readOnly = MountScript.build(sampleInputs(kind: .microsoft, readOnly: true))
    expect(!readOnly.contains("--ignore-permissions"), "read-only does not ask for the pair")
    expect(readOnly.contains("--nfs-export-opts="), "it names the export instead")
    expect(
        readOnly.contains("all_squash,anonuid=501,anongid=20"),
        "and says the files belong to whoever opened the drive, which is what the other flag did")
    expect(readOnly.contains(" -o ro"), "the guest still mounts read-only")

    // A writable mount is unchanged, and its read-only fallback asks the new
    // way -- so a drive that refuses to be written to still opens.
    let writable = MountScript.build(sampleInputs(kind: .microsoft, readOnly: false))
    let first =
        writable.components(separatedBy: "anylinuxfs' mount").dropFirst().first
        ?? ""
    expect(first.contains("--ignore-permissions"), "the first attempt asks as it always did")
    expect(!first.contains("nfs-export-opts"), "and does not name the export")
    expect(
        writable.contains("--nfs-export-opts="),
        "while the read-only fallback further down does")

    // Every attempt, not merely the first.
    for attempt in readOnly.components(separatedBy: "anylinuxfs' mount").dropFirst() {
        let command = attempt.components(separatedBy: ">>").first ?? ""
        expect(
            !command.contains("--ignore-permissions"),
            "no attempt asks for the combination the engine refuses")
    }
}

group("theMountScriptIsValidShell") {
    // The script is generated, handed to a privileged helper and run there. A
    // shell that cannot parse it exits 2 before anything happens, which the app
    // reports as a drive that would not open.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lukotta-script-check", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, script) in [
        ("write, microsoft", MountScript.build(sampleInputs(kind: .microsoft, readOnly: false))),
        ("read-only, microsoft", MountScript.build(sampleInputs(kind: .microsoft, readOnly: true))),
        ("write, linux", MountScript.build(sampleInputs(kind: .linux, readOnly: false))),
        ("read-only, linux", MountScript.build(sampleInputs(kind: .linux, readOnly: true))),
    ] {
        let file = dir.appendingPathComponent("check.sh")
        try? script.write(to: file, atomically: true, encoding: .utf8)
        let out = run("/bin/sh", ["-n", file.path])
        expect(out?.status == 0, "\(name): the shell parses it")
        if out?.status != 0 { print("      \(out?.combined ?? "")") }
    }
    try? FileManager.default.removeItem(at: dir)
}

group("aLaunchNobodyAskedForIsTheOnlyOneWithoutAWindow") {
    // The window was suppressed by reading XPC_SERVICE_NAME, which launchd once
    // set to "0" for a launch from the Dock and to a job name for a login item.
    // Every launch now gets a job name, so the app started, ran, and put nothing
    // on screen -- indistinguishable from an app that does not launch.
    //
    // The rule is in LukottaApp.swift. Pinned by reading it, the app target not
    // being linked into these checks.
    let source =
        (try? String(contentsOfFile: "sources/Lukotta/LukottaApp.swift", encoding: .utf8)) ?? ""

    expect(
        !source.contains("environment[\"XPC_SERVICE_NAME\"]"),
        "nothing decides this from a job name launchd gives every launch")
    expect(
        !source.contains(".defaultLaunchBehavior"),
        "and no scene refuses to open before anyone knows who asked")
    expect(
        source.contains("guard !NSApp.isActive else { return }")
            && source.contains("NSApp.hide(nil)"),
        "a person opening an app activates it; launchd does not")
    expect(
        source.contains("asyncAfter(deadline: .now() + LaunchContext.settle)"),
        "and the question waits, activation not always beating the end of launching")
}

group("aRefusalNamesThePermissionThatWasRefused") {
    // Full Disk Access and the removable-volumes permission are refused in the
    // same words by the engine, and the app used to send both to the Full Disk
    // Access screen -- naming, for one of them, a permission already granted.
    //
    // The rule is in reportRefusal. Pinned by reading it, the app target not
    // being linked into these checks.
    let source =
        (try? String(contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    guard let start = source.range(of: "private func reportRefusal("),
        let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
    else { return expect(false, "reportRefusal was found") }
    let body = String(source[start.upperBound..<end.lowerBound])

    expect(
        body.contains("Permissions.reading()"),
        "the record is read again rather than trusted from start-up")
    expect(
        body.contains("!reading.fullDiskAccess"),
        "Full Disk Access is what the permission screen is for")
    expect(body.contains("phase = .needsPermission"), "and that is where it sends them")
    expect(
        body.contains("removableAccess == false"),
        "a refused removable-volumes permission is told apart from it")
    expect(
        body.contains("phase = .unlock(drive)"),
        "and goes back to the screen whose panel holds that setting")
    expect(
        body.contains("self.fail("),
        "a refusal nothing accounts for still reports the engine's own words")
}

group("aBlockedRestoreExplainsItself") {
    // Restoring runs with nobody watching, so a failure says nothing. A missing
    // permission is the exception: the drives cannot come back at all, and the
    // reason is one only the person can fix.
    //
    // The rule is in restoreRememberedMounts. Pinned here by reading it, since
    // the app target is not linked into these checks.
    let source =
        (try? String(contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    guard let start = source.range(of: "func restoreRememberedMounts()"),
        let end = source.range(of: "\n    }", range: start.upperBound..<source.endIndex)
    else { return expect(false, "restoreRememberedMounts was found") }
    let body = String(source[start.upperBound..<end.lowerBound])

    expect(body.contains("!hasFullDiskAccess"), "it looks at the permission before trying")
    expect(
        body.contains("restoreBlocked = true"),
        "and says why the permission screen is being shown")
    expect(body.contains("phase = .needsPermission"), "which is the screen it shows")
    // A container file is opened without any privilege, so a missing
    // permission must not stop one coming back.
    expect(
        body.contains("$0.imagePath == nil"),
        "only drives needing the raw device are affected")
}

group("theRestoreRecordCarriesThisMountsReadOnlyState") {
    // Bookkeeping this mount's success is one function for all three routes.
    // Written out a second time for the authorised route, the copy recorded the
    // restore entry before working out whether the mount had fallen back to
    // read-only, so the entry carried the previous mount's answer.
    //
    // The order is what is being pinned: whatever decides mountedReadOnly must
    // run before whatever reads it.
    let source =
        (try? String(
            contentsOfFile: "sources/Lukotta/AppModel.swift", encoding: .utf8)) ?? ""
    guard let body = source.range(of: "private func finishMount(") else {
        return expect(false, "finishMount was found in the file")
    }
    let after = String(source[body.upperBound...])
    guard let decides = after.range(of: "mountedReadOnly = mountingReadOnly || fellBack"),
        let reads = after.range(of: "rememberForRestore(drive, readOnly: mountedReadOnly)")
    else {
        return expect(false, "both statements were found")
    }
    expect(
        decides.lowerBound < reads.lowerBound,
        "the read-only state is decided before the restore record reads it")
}

group("aReportBuiltInTwoPartsMatchesOneBuiltAtOnce") {
    // The sheet redacts everything but the typed description once, when it
    // opens, and splices the description in as it is typed. What that produces
    // has to be the report itself, or the two would drift.
    let env = Diagnostics.environment()
    let engine = "mount: /dev/disk4s1 on /Volumes/BACKUP"
    let log = "started"
    let typed = "it would not open, passphrase: hunter2"

    let atOnce = Diagnostics.report(
        environment: env, problem: typed, engineOutput: engine, recentLog: log)
    let inTwoParts = Diagnostics.withProblem(
        typed,
        in: Diagnostics.report(environment: env, engineOutput: engine, recentLog: log))
    expect(inTwoParts == atOnce, "the two ways of building it agree")
    expect(!inTwoParts.contains("hunter2"), "and the typed part is still redacted")

    let empty = Diagnostics.report(environment: env, engineOutput: engine)
    expect(
        Diagnostics.withProblem("", in: empty) == empty,
        "nothing typed leaves the report as it was")
}

group("crashReportFiltering") {
    // A crash from an older build, offered beside an unrelated failure, reads as
    // a crash that has just happened. A cancelled authorisation was reported
    // that way.
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    // Any report of ours that records a build. A process that died before it
    // finished loading has a header with the fields empty -- there was no
    // application yet to have a version -- and that is the report saying so
    // rather than the reading being wrong.
    if let found = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
        let sample = found.sorted().reversed().first(where: {
            $0.hasPrefix("Lukotta") && $0.hasSuffix(".ips")
                && Diagnostics.buildRecorded(in: dir.appendingPathComponent($0))?.isEmpty == false
        })
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
    // A saved credential that cannot be read back is worse than not offering to
    // save one, since it is then believed to be stored.
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
    //
    // Made up, and shaped like a real one. The team this project signs with is
    // read from the running bundle; writing it here would put it in the
    // repository for no reason.
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

    // The engine's own test: size first, then whether the bundled one is
    // newer.
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

    // Copying keeps the timestamp, so the two match afterwards. That must read
    // as settled, or every launch would copy again.
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
    // Waking is not a single moment. The host returns before the microVM does,
    // and the mount cannot answer until the network between them carries traffic
    // again, so asking once and giving up would report every healthy drive as
    // dead.
    expect(WakeRecovery.nextDelay(after: 0) != nil, "a mount is asked more than once")

    // Doubling, so that a wedged mount is not asked sixty times in sixty
    // seconds.
    let first = WakeRecovery.nextDelay(after: 0) ?? 0
    let later = WakeRecovery.nextDelay(after: 20) ?? 0
    expect(later > first, "the wait grows as the silence goes on")
    expect(WakeRecovery.nextDelay(after: 100) ?? 0 <= 16, "and stops growing")

    // The grace period is a ceiling. A delay running past it would leave a dead
    // mount in the list for longer than the period states.
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
    // A report beginning in the middle reads as though nothing preceded it, so
    // a truncated log records that it was truncated.
    let short = ["one", "two"]
    expect(Diagnostics.tail(of: short, limit: 5), "one\ntwo", "nothing is said when nothing is cut")

    let long = (1...10).map { "line \($0)" }
    let cut = Diagnostics.tail(of: long, limit: 3)
    expect(cut.contains("7 earlier lines not shown"), "the count of what was dropped is stated")
    expect(cut.hasSuffix("line 8\nline 9\nline 10"), "and the newest lines are the ones kept")
    expect(!cut.contains("line 7"), "the dropped ones are gone")

    // The report carries the log through the same redaction as everything else.
    // A passphrase echoed by the pty must not reach it by this route.
    let environment = Diagnostics.environment()
    let body = Diagnostics.report(
        environment: environment,
        recentLog: "mount password: hunter2000\n123456-123456-123456-123456-123456")
    expect(body.contains("What the app was doing:"), "the log is a section of its own")
    expect(!body.contains("hunter2000"), "a labelled secret in the log is redacted")
    expect(!body.contains("123456-123456"), "and so is a recovery key")

    // Nothing to report produces no heading rather than an empty one.
    let empty = Diagnostics.report(environment: environment, recentLog: "")
    expect(!empty.contains("What the app was doing:"), "an empty log adds no section")
}

group("theLogIsReadableBack") {
    // A report is useful only if what was written can be found again under the
    // subsystem it was written to. A report reading one name while the logger
    // writes another is empty and gives no sign of it.
    let marker = "log round trip \(ProcessInfo.processInfo.processIdentifier)"
    Log.app.notice("\(marker, privacy: .public)")
    // The store is written to asynchronously; give it a moment to land.
    Thread.sleep(forTimeInterval: 0.5)
    let text = Diagnostics.recentLog(within: 60)
    expect(text.contains(marker), "a line just written is found again")
    expect(text.contains("app"), "and carries the category it was written under")
}

group("driveScannerParsing") {
    // Shaped like `diskutil list -plist physical`, with invented names. What is
    // checked is which partitions are picked up and what they are called.
    let list: [String: Any] = [
        "AllDisksAndPartitions": [
            // The internal disk, none of which is offered.
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
            // A disk with no partition list at all: one volume filling the
            // disk, which is what cryptsetup leaves behind.
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

    expect(
        "\(found.count)", "3",
        "only the partitions we can do something with are listed, plus the disk with none")
    expect(
        found.map(\.id).joined(separator: ","), "disk4s1,disk5s2,disk6",
        "in the order they appear, the unpartitioned disk last with its own name")

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
    // No UUID anywhere -- an MBR table carries none -- so the drive is named by
    // what does not change when it is unplugged and put back somewhere else.
    // Named by its device instead, a saved passphrase was stored against
    // disk4s1 and looked for under disk5s1.
    expect(
        linux.uuid, "media:Generic-Media:1000:0",
        "a partition with no UUID is named by its medium, size and offset")
    expect(
        DriveScanner.stableName(media: "Patriot Memory", size: 247_630_659_584, offset: 1_048_576)
            ?? "",
        "media:Patriot-Memory:247630659584:1048576", "the parts that do not change, joined")
    expect(
        DriveScanner.stableName(media: nil, size: 1_000, offset: 0) == nil,
        "and nothing at all when there is not enough to tell one drive from another")
    expect(
        DriveScanner.stableName(media: "Disk Image", size: 0, offset: 0) == nil,
        "a size of zero is not an identity")

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

    // The volume's own name takes precedence over the drive's, and the size can
    // come from either plist, the list omitting it for some partitions.
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

    // It holds a credential pipe. Readable by anyone else, the FIFO would serve
    // no purpose.
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

    // A stand-in for the bundled rootfs. Unpacking is judged by whether "rootfs"
    // ends up on disk rather than by tar's exit status alone. The real archive is
    // not unpacked by a test.
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
    expect(
        !fm.fileExists(atPath: broken.path + ".unpacking"),
        "nor half-unpacked beside it")

    // What a crash, a forced quit or a Mac going to sleep leaves: a directory
    // with a rootfs in it and nothing finished. Unpacking happens beside the
    // real one, so the environment in use is never the half-made one.
    let interrupted = temp.appendingPathComponent("alpine", isDirectory: true)
        .deletingLastPathComponent().appendingPathComponent("alpine.unpacking", isDirectory: true)
    try! fm.createDirectory(
        at: interrupted.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
    try! "half".write(
        to: target.appendingPathComponent("rootfs/etc/hostname"), atomically: true, encoding: .utf8)
    _ = try? EngineEnvironment.prepare(into: target, from: archive) { _ in }
    expect(
        !fm.fileExists(atPath: interrupted.path),
        "and what an interrupted run left is cleared rather than used")
    expect(EngineEnvironment.isReady(in: target), "the environment in use is untouched by it")
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
    // report an encrypted drive as unencrypted.
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

    // Nothing recognised produces no statement. A wrong answer here sends
    // someone looking for a password that does not exist.
    // A container file made with cryptsetup has no partition table at all, so
    // this is the only thing that says what it is.
    var luks = [UInt8](repeating: 0, count: BootSector.length)
    for (i, b) in BootSector.luksMagic.enumerated() { luks[i] = b }
    expect("\(BootSector.identify(Data(luks)))", "luks", "a LUKS container names itself first")

    // Only at the start. Six bytes occur by chance often enough that matching
    // them anywhere would identify other things as LUKS.
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
    // All of this matches on text, the engine exiting 0 whether or not the mount
    // worked and leaving nothing else to match on. The failure to guard against
    // is an upgrade rewording a phrase, after which every rule stops firing and
    // raw output is shown for a release or two before anyone notices.
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
        // A test that cannot find what it checks is not running.
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

    // Output with no matching rule falls through to the engine's own words.
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
    // the virtual machine. Beyond that the engine is not returning rather than
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
    // End to end: a file with a LUKS header, attached by macOS, recognised, and
    // detached again. No engine and no root, an attached image belonging to
    // whoever attached it.
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

        // No partition table, so the disk itself is the volume -- listed the
        // same way a stick that cryptsetup was given whole is listed.
        let listed = DriveScanner.scan(images: [attached.identifier])
            .filter { DriveScanner.wholeDisk(of: $0.id) == attached.identifier }
        expect(listed.count == 1, "a container with no partition table is the one volume on it")
        expect(listed.first?.id == attached.identifier, "named after the disk, having no partition")

        let drive = DiskImage.wholeDiskDrive(attached, url: file)
        expect(drive != nil, "but the whole disk is recognised from its first sector")
        expect("\(drive?.kind ?? .microsoft)", "linux", "as a Linux container")
        expect(drive?.name ?? "", "container", "named after the file, without the extension")
        expect(
            drive?.uuid ?? "", file.path,
            "and identified by the file, so a saved passphrase survives reattaching")

        expect(DiskImage.detach(attached.device), "and it detaches again")
    }

    // A file that is not an image still attaches, a raw image being only bytes,
    // so attaching does not establish that a file is openable. Its contents do:
    // a text file holds nothing recognisable and is detached again.
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
    // A container with no partition table is a row the scan cannot produce,
    // diskutil reporting the disk as empty. The row was added once when the file
    // was opened, and the next refresh, from a drive being plugged in or a mount
    // finishing, rebuilt the list without it. The app then reported the drive as
    // disconnected while the mount it was serving continued to work.
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

    // Once the scan can see it, from a container that has a partition table or
    // the same disk reappearing, it is not added twice.
    let partition = Drive(
        id: "disk7s1", devicePath: "/dev/disk7s1", name: "backup", sizeBytes: 320,
        connection: "Disk Image", kind: .linux, uuid: "UUID-2")
    let once = ImageList.merge(found: [partition], images: ["disk7": image])
    expect("\(once.count)", "1", "a container the scan can see is not listed twice")

    // A container with no partition table is offered by the scan as the disk
    // itself, under the name of the device it was attached on. The row built
    // from the file says the same thing in terms that outlive the attachment,
    // and takes its place.
    let asTheDevice = Drive(
        id: "disk7", devicePath: "/dev/disk7", name: "disk7", sizeBytes: 320,
        connection: "Disk Image", kind: .linux, uuid: "disk7")
    let replaced = ImageList.merge(found: [physical, asTheDevice], images: ["disk7": image])
    expect("\(replaced.count)", "2", "it is one row and not two")
    expect(
        replaced.contains { $0.uuid == image.uuid },
        "and it is the row that knows which file it came from")

    // Ejecting is what takes it out, and only the one that was ejected.
    let ejected = ImageList.detaching(devices: ["/dev/disk7"], images: ["disk7", "disk9"])
    expect(ejected.joined(separator: ","), "disk7", "ejecting a container detaches that container")
    let untouched = ImageList.detaching(devices: ["/dev/disk4s1"], images: ["disk7"])
    expect(untouched.isEmpty, "and ejecting something else leaves it alone")
    // A container with a partition table is listed by the scan, so it never
    // needed a row made for it -- and used to stay attached when it was ejected.
    let partitioned = ImageList.detaching(devices: ["/dev/disk7s1"], images: ["disk7"])
    expect(
        partitioned.joined(separator: ","), "disk7",
        "and ejecting a volume inside a container puts the file back")
}

group("unencryptedFilesystemsNeedNoPassword") {
    // A container or drive holding an ordinary filesystem has nothing to unlock,
    // and asking for its passphrase asks for something that does not exist. Each
    // filesystem writes its magic at one offset.
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
    // btrfs writes its signature 64 KB in, so a single sector is not enough.
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

    // Encryption takes precedence wherever it appears. The reverse would report
    // an encrypted drive as needing no password.
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
    // The app is needed only where macOS cannot manage. macOS mounts exFAT
    // locally, read and write, and opening one here would turn a local volume
    // into a network one to no purpose.
    expect(VolumeFormat.exfat.macOSHandlesFully, "exFAT is left to macOS")

    // NTFS is not on that list. macOS mounts it read-only, and writing to it is
    // the reason to open one here.
    expect(!VolumeFormat.ntfs.macOSHandlesFully, "NTFS is not, because macOS only reads it")
    for format in [VolumeFormat.ext, .btrfs, .xfs] {
        expect(!format.macOSHandlesFully, "\(format) is not, because macOS cannot read it at all")
    }
    for format in [VolumeFormat.luks, .bitlocker] {
        expect(!format.macOSHandlesFully, "\(format) is not, because it is encrypted")
    }

    // Everything macOS handles fully is unencrypted, and the two together decide
    // whether a drive opens without being asked.
    for format in [VolumeFormat.bitlocker, .luks, .ntfs, .exfat, .ext, .btrfs, .xfs, .unknown] {
        if format.macOSHandlesFully {
            expect(format.isUnencrypted, "\(format) is handled by macOS and so has no password")
        }
    }
}

group("qcow2ContainersAreReadByTheEngine") {
    // macOS cannot attach a qcow2. The engine reads the format itself and is
    // handed the path, so no sector read here sees inside and the engine's
    // listing is the only account.
    let listing = """

        /Users/someone/vm.qcow2 (disk image):
           #:                       TYPE NAME                    SIZE       IDENTIFIER
           0:                crypto_LUKS                        +335.5 MB   vm.qcow2
        """
    expect(
        DiskImage.types(inListing: listing).joined(separator: ","), "crypto_LUKS",
        "the type column is read and the header is not")
    expect(
        "\(DiskImage.format(fromTypes: DiskImage.types(inListing: listing)))", "luks",
        "an encrypted volume means a passphrase is wanted")

    let plain = """
           #:                       TYPE NAME                    SIZE       IDENTIFIER
           0:                      btrfs LUKOTTAPLAIN           +335.5 MB   plain.qcow2
        """
    expect(
        "\(DiskImage.format(fromTypes: DiskImage.types(inListing: plain)))", "btrfs",
        "and an ordinary filesystem means none is")

    // With several volumes, any encrypted one decides the answer, the engine
    // having to open the container before it can see past it.
    expect(
        "\(DiskImage.format(fromTypes: ["ext4", "crypto_LUKS"]))", "luks",
        "one encrypted volume among several still means a passphrase")
    expect("\(DiskImage.format(fromTypes: ["ntfs"]))", "ntfs", "NTFS is recognised")
    expect(
        "\(DiskImage.format(fromTypes: ["swap", "unknown"]))", "unknown",
        "and nothing recognisable is not guessed at")
    expect("\(DiskImage.format(fromTypes: []))", "unknown", "nor is an empty listing")

    // Rows are found by their number, so a stray line cannot become a volume.
    expect(
        DiskImage.types(inListing: "no rows here at all").isEmpty,
        "prose in the listing is not mistaken for a volume")
}

group("surveyingEveryDisk") {
    // "No encrypted drives found" says nothing about the drive on the desk. This
    // is the other view: everything attached, with a reason beside each disk that
    // cannot be opened.
    let list: [String: Any] = [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme",
                "Partitions": [
                    ["DeviceIdentifier": "disk0s1", "Content": "Apple_APFS_ISC"],
                    ["DeviceIdentifier": "disk0s2", "Content": "Apple_APFS"],
                ],
            ],
            [
                "DeviceIdentifier": "disk3", "Content": "Apple_APFS_Container",
                "APFSVolumes": [
                    ["DeviceIdentifier": "disk3s1", "VolumeName": "Macintosh HD"]
                ],
            ],
            [
                "DeviceIdentifier": "disk4", "Content": "GUID_partition_scheme",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk4s1", "Content": "Microsoft Basic Data",
                        "Size": NSNumber(value: 500),
                    ]
                ],
            ],
            [
                "DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme",
                "Partitions": [
                    [
                        "DeviceIdentifier": "disk6s1", "Content": "Microsoft Basic Data",
                        "VolumeName": "STICK", "Size": NSNumber(value: 64),
                    ]
                ],
            ],
        ]
    ]
    let openable = [
        Drive(
            id: "disk4s1", devicePath: "/dev/disk4s1", name: "Elements", sizeBytes: 500,
            connection: "USB", kind: .microsoft, uuid: "U1")
    ]
    let mounts = "/dev/disk6s1 on /Volumes/STICK (exfat, local, nodev)\n"
    let info: [String: [String: Any]] = [
        "disk0": ["Internal": true], "disk3": ["Internal": true],
        "disk4": ["Internal": false, "MediaName": "Elements"],
        "disk6": ["Internal": false, "MediaName": "Stick"],
    ]
    let entries = DriveSurvey.survey(
        list: list, info: { info[$0] ?? [:] }, mountTable: mounts, openable: openable)

    func verdict(_ id: String) -> String {
        guard let e = entries.first(where: { $0.id == id }) else { return "absent" }
        switch e.verdict {
        case .openable: return "openable"
        case .openHere(let p, let ro): return "ours:" + p + (ro ? ":ro" : "")
        case .macOSHasIt(let p): return "mounted:" + p
        case .macOSReadsIt: return "macOS"
        case .system: return "system"
        case .unreadable: return "unreadable"
        }
    }

    expect(verdict("disk4s1"), "openable", "a locked drive is offered")

    // A drive this app has already unlocked is not one to unlock again. Opening
    // it a second time started another machine for a device the first was still
    // serving, and the row said "Open" beside a drive that was already open.
    let ours = DriveSurvey.survey(
        list: list, info: { info[$0] ?? [:] }, mountTable: mounts, openable: openable,
        openHere: ["/dev/disk4s1": (point: "/Users/someone/Volumes/BACKUP", readOnly: false)])
    func ourVerdict(_ id: String) -> String {
        guard let e = ours.first(where: { $0.id == id }) else { return "absent" }
        if case .openHere(let p, let ro) = e.verdict { return "ours:" + p + (ro ? ":ro" : "") }
        if case .openable = e.verdict { return "openable" }
        return "other"
    }
    expect(
        ourVerdict("disk4s1"), "ours:/Users/someone/Volumes/BACKUP",
        "a drive this app already has open says so, and offers to eject it")
    let readOnly = DriveSurvey.survey(
        list: list, info: { info[$0] ?? [:] }, mountTable: mounts, openable: openable,
        openHere: ["/dev/disk4s1": (point: "/Users/someone/Volumes/BACKUP", readOnly: true)])
    expect(
        {
            if case .openHere(_, let ro) = readOnly.first(where: { $0.id == "disk4s1" })?.verdict {
                return ro
            }
            return false
        }(), "and one opened read-only carries that too")

    expect(entries.first(where: { $0.id == "disk4s1" })?.drive != nil, "and carries the drive")
    expect(verdict("disk6s1"), "mounted:/Volumes/STICK", "one macOS already has says where")
    expect(verdict("disk0s1"), "system", "the boot disk's own partitions are not offered")
    expect(verdict("disk0s2"), "system", "nor is its APFS container")
    expect(verdict("disk3s1"), "system", "nor Macintosh HD")

    // Every disk is accounted for, a missing drive being what sends someone to
    // this view in the first place.
    expect("\(entries.count)", "5", "every partition and volume is listed")
    expect(
        entries.first(where: { $0.id == "disk6s1" })?.name ?? "", "STICK",
        "named by its volume where it has one")
    expect(
        entries.first(where: { $0.id == "disk4s1" })?.name ?? "", "Elements",
        "and by the drive's own name where it does not")

    // A disk with no partition table at all still appears.
    let bare: [String: Any] = [
        "AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk9", "Content": "", "Size": NSNumber(value: 100)]
        ]
    ]
    let one = DriveSurvey.survey(list: bare, info: { _ in [:] }, mountTable: "", openable: [])
    expect("\(one.count)", "1", "a disk with nothing on it is still listed")
    expect(one.first?.id ?? "", "disk9", "as the whole disk")
}

group("aQcow2ThatNamesAnotherFile") {
    // libkrun's own header states that formats other than raw can reference
    // other files, which libkrun opens. A file handed to this app could
    // therefore determine which other files the virtual machine reads. Container
    // files run unprivileged, which limits the reach to what the person who
    // opened it could already read, bounding the consequence rather than
    // justifying it.
    func header(
        version: UInt32 = 3, backingOffset: UInt64 = 0, backingSize: UInt32 = 0,
        features: UInt64 = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        bytes[0] = 0x51
        bytes[1] = 0x46
        bytes[2] = 0x49
        bytes[3] = 0xFB
        func put32(_ v: UInt32, _ at: Int) {
            for i in 0..<4 { bytes[at + i] = UInt8((v >> (8 * (3 - UInt32(i)))) & 0xFF) }
        }
        func put64(_ v: UInt64, _ at: Int) {
            for i in 0..<8 { bytes[at + i] = UInt8((v >> (8 * (7 - UInt64(i)))) & 0xFF) }
        }
        put32(version, 4)
        put64(backingOffset, 8)
        put32(backingSize, 16)
        put64(features, 72)
        put32(104, 100)
        return Data(bytes)
    }

    let plain = Qcow2Header.parse(header())
    expect(plain != nil, "an ordinary qcow2 header parses")
    expect(!(plain?.namesAnotherFile ?? true), "and names nothing else")

    let backed = Qcow2Header.parse(header(backingOffset: 512, backingSize: 21))
    expect(backed?.namesABackingFile ?? false, "a backing file is seen")
    expect(backed?.namesAnotherFile ?? false, "and counts as naming another file")

    let external = Qcow2Header.parse(header(features: 1 << 2))
    expect(external?.usesExternalDataFile ?? false, "an external data file is seen")
    expect(external?.namesAnotherFile ?? false, "and counts too")

    let corrupt = Qcow2Header.parse(header(features: 1 << 1))
    expect(corrupt?.isCorrupt ?? false, "the corrupt bit is read")
    expect(!(corrupt?.namesAnotherFile ?? true), "and is a different objection")

    // An offset with no length is not a backing file, and the pair is what the
    // specification calls one.
    expect(
        !(Qcow2Header.parse(header(backingOffset: 512))?.namesABackingFile ?? true),
        "an offset with no name is not a backing file")

    // Version 2 has no feature field at all; reading one would be reading
    // whatever follows the header.
    let v2 = Qcow2Header.parse(header(version: 2, features: 1 << 2))
    expect(v2?.incompatibleFeatures == 0, "version 2 carries no feature bits")

    // Not a qcow2, and a truncated one.
    expect(Qcow2Header.parse(Data([0x51, 0x46])) == nil, "a couple of bytes is not a header")
    expect(Qcow2Header.parse(Data(repeating: 0, count: 100)) == nil, "nor is a run of zeroes")
    expect(
        Qcow2Header.parse(header(version: 9)) == nil, "nor a version nobody has defined")

    // The extension area names one too, and the two are meant to agree. A
    // file setting one without the other is exactly what to refuse rather than
    // reason about.
    var withExtension = [UInt8](header())
    withExtension[104] = 0x44
    withExtension[105] = 0x41
    withExtension[106] = 0x54
    withExtension[107] = 0x41
    withExtension[111] = 8
    expect(
        Qcow2Header.hasExternalDataExtension(Data(withExtension)),
        "an external data file named in the extension area is found")
    expect(
        !Qcow2Header.hasExternalDataExtension(header()),
        "and an image without one is not accused of it")
}

group("aVmdkNamesAnotherFileByDesign") {
    // A VMDK names a separate file for its data, the descriptor being read whole
    // and capped at two megabytes, so no self-contained form exists. The rule is
    // therefore that it names only what sits beside it.
    let ordinary = """
        # Disk DescriptorFile
        version=1
        CID=fffffffe
        parentCID=ffffffff
        createType="monolithicFlat"

        RW 655360 FLAT "disk-flat.vmdk" 0

        ddb.geometry.heads = "16"
        """
    let d = VmdkDescriptor.parse(ordinary)
    expect("\(d.extents.count)", "1", "the extent is read")
    expect(d.extents.first?.filename ?? "", "disk-flat.vmdk", "with the name it points at")
    expect("\(d.extents.first?.sectors ?? 0)", "655360", "and its length")
    expect(d.createType ?? "", "monolithicFlat", "the create type is unquoted")
    expect(!d.namesAFileElsewhere, "a name beside the descriptor is allowed")
    expect(!d.hasDeltaLink, "and it is not part of a chain")

    // A descriptor must not reach anywhere outside its own folder.
    for reach in ["/etc/passwd", "../../secrets.img", "sub/dir/disk.vmdk", ""] {
        expect(
            VmdkDescriptor.reachesElsewhere(reach), "“\(reach)” is refused as an extent name")
    }
    for beside in ["disk-flat.vmdk", "disk-s001.vmdk", "a file with spaces.vmdk"] {
        expect(!VmdkDescriptor.reachesElsewhere(beside), "“\(beside)” sits beside it")
    }

    let elsewhere = VmdkDescriptor.parse("RW 100 FLAT \"/etc/passwd\" 0")
    expect(elsewhere.namesAFileElsewhere, "a descriptor pointing outside is seen")

    // A name with spaces is taken from the quotes, not from the split.
    let spaced = VmdkDescriptor.parse("RW 100 FLAT \"my disk-flat.vmdk\" 0")
    expect(spaced.extents.first?.filename ?? "", "my disk-flat.vmdk", "quoted names survive spaces")

    // ZERO extents hold nothing and name nothing, so they cannot reach out.
    let zero = VmdkDescriptor.parse("RW 4096 ZERO")
    expect(zero.extents.first?.filename == nil, "a ZERO extent names no file")
    expect(!zero.namesAFileElsewhere, "and cannot reach anywhere")

    // Several extents, of which one bad entry is enough to refuse the file.
    let mixed = VmdkDescriptor.parse(
        """
        RW 100 FLAT "a-flat.vmdk" 0
        RW 100 FLAT "../b-flat.vmdk" 0
        """)
    expect("\(mixed.extents.count)", "2", "both extents are read")
    expect(mixed.namesAFileElsewhere, "and one reaching out condemns the set")

    // An extent that holds data but names no file. VMware always quotes the
    // name; without one the line describes part of a disk that is nowhere, and
    // it used to pass every objection — a missing name reads as naming nothing
    // elsewhere, and the every-file-is-present check skipped it.
    let unnamed = VmdkDescriptor.parse("RW 655360 FLAT")
    expect(unnamed.hasAnExtentWithNoFile, "an extent with no file is seen")
    expect(!unnamed.namesAFileElsewhere, "which is not the same objection")
    expect(!VmdkDescriptor.parse("RW 4096 ZERO").hasAnExtentWithNoFile, "a ZERO extent is fine")
    expect(
        !VmdkDescriptor.parse("RW 100 FLAT \"a-flat.vmdk\" 0").hasAnExtentWithNoFile,
        "and so is a named one")

    // Against the whole check, with files on disk: a plain name may still be a
    // link out of the folder, and following it opens a file the descriptor was
    // not allowed to name outright.
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lukotta-vmdk-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: sandbox, withIntermediateDirectories: true)
    let descriptorFile = sandbox.appendingPathComponent("disk.vmdk")
    try? "RW 655360 FLAT \"disk-flat.vmdk\" 0\n".write(
        to: descriptorFile, atomically: true, encoding: .utf8)
    let dataFile = sandbox.appendingPathComponent("disk-flat.vmdk")
    try? Data(count: 512).write(to: dataFile)
    expect(DiskImage.objection(toVmdk: descriptorFile) == nil, "a set of files beside it opens")

    let outside = sandbox.appendingPathComponent("elsewhere.img")
    try? Data(count: 512).write(to: outside)
    let awayFile = sandbox.appendingPathComponent("away", isDirectory: true)
    try? FileManager.default.createDirectory(at: awayFile, withIntermediateDirectories: true)
    let target = awayFile.appendingPathComponent("secret.img")
    try? Data(count: 512).write(to: target)
    try? FileManager.default.removeItem(at: dataFile)
    try? FileManager.default.createSymbolicLink(at: dataFile, withDestinationURL: target)
    expect(
        DiskImage.objection(toVmdk: descriptorFile)?.contains("another file") ?? false,
        "a link out of the folder is refused, as a path out of it would be")

    try? "RW 655360 FLAT\n".write(to: descriptorFile, atomically: true, encoding: .utf8)
    expect(DiskImage.objection(toVmdk: descriptorFile) != nil, "so is an extent naming no file")
    try? FileManager.default.removeItem(at: sandbox)

    // A snapshot chain names a parent elsewhere, which the engine does not
    // follow.
    let delta = VmdkDescriptor.parse("parentFileNameHint=\"base.vmdk\"")
    expect(delta.hasDeltaLink, "a delta link is seen")

    // Comments and blank lines are not extents.
    let noisy = VmdkDescriptor.parse("# RW 100 FLAT \"x\" 0\n\n   \n")
    expect(noisy.extents.isEmpty, "a commented-out extent is not an extent")
}

group("aFixedVhdIsAlreadyRaw") {
    // A fixed VHD is the raw disk followed by a 512-byte footer, so every
    // partition table and superblock lies at its natural offset and any engine
    // opens one. The other forms are not raw, so they are identified here.
    func footer(kind: UInt32, size: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array("conectix".utf8).enumerated() { bytes[i] = b }
        for i in 0..<8 { bytes[48 + i] = UInt8((size >> (8 * (7 - UInt64(i)))) & 0xFF) }
        for i in 0..<4 { bytes[60 + i] = UInt8((kind >> (8 * (3 - UInt32(i)))) & 0xFF) }
        return Data(bytes)
    }

    let fixed = VhdFooter.parse(footer(kind: 2, size: 1024))
    expect(fixed?.kind == .fixed, "a fixed VHD is recognised")
    expect("\(fixed?.currentSize ?? 0)", "1024", "and says how much disk it holds")

    expect(VhdFooter.parse(footer(kind: 3, size: 1024))?.kind == .dynamic, "dynamic too")
    expect(
        VhdFooter.parse(footer(kind: 4, size: 1024))?.kind == .differencing,
        "and differencing, which names a parent disk")

    // A value the format does not define is not guessed at.
    expect(VhdFooter.parse(footer(kind: 9, size: 1024))?.kind == nil, "an unknown type is unknown")

    // Without the cookie it is not a VHD, whatever its name.
    var noCookie = [UInt8](repeating: 0, count: 512)
    noCookie[0] = 0x41
    expect(VhdFooter.parse(Data(noCookie)) == nil, "no cookie, no footer")
    expect(VhdFooter.parse(Data(repeating: 0, count: 8)) == nil, "and a short read is not one")
}

group("aVdiIsNeverRawAtAnyOffset") {
    // A VDI holds its blocks in the order they were written, so no part of the
    // disk lies at the offset the disk gives. What is read here distinguishes
    // one from a file that merely ends in .vdi.
    func header(kind: UInt32, version: UInt32 = 0x0001_0001, size: UInt64 = 1 << 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: VdiHeader.length)
        func le(_ value: UInt64, _ at: Int, _ width: Int) {
            for i in 0..<width { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        le(UInt64(VdiHeader.signature), VdiHeader.signatureOffset, 4)
        le(UInt64(version), 0x44, 4)
        le(UInt64(kind), 0x4C, 4)
        le(size, 0x170, 8)
        return Data(bytes)
    }

    let dynamic = VdiHeader.parse(header(kind: 1))
    expect(dynamic?.kind == .dynamic, "a VDI holding only what was written is recognised")
    expect("\(dynamic?.diskSize ?? 0)", "1048576", "and says how much disk it stands for")
    expect(VdiHeader.parse(header(kind: 2))?.kind == .fixed, "and one holding every block")
    expect(VdiHeader.parse(header(kind: 7))?.kind == nil, "an unknown kind is unknown")

    // Version 0 laid the header out differently, so reading it as version 1
    // locates the block map at the wrong offset.
    expect(VdiHeader.parse(header(kind: 1, version: 0))?.major == 0, "the version is read")

    var wrongMagic = [UInt8](repeating: 0, count: VdiHeader.length)
    wrongMagic[VdiHeader.signatureOffset] = 0x7f
    expect(VdiHeader.parse(Data(wrongMagic)) == nil, "no signature, no VDI")
    expect(VdiHeader.parse(Data(repeating: 0, count: 64)) == nil, "and a short read is not one")
}

group("aSparseVmdkCarriesItsDescriptorInside") {
    // A sparse VMDK is the disk rather than a text file describing one. The
    // descriptor that a flat VMDK keeps in a separate file is stored within it,
    // at an offset the header gives.
    func header(flags: UInt32, at: UInt64 = 1, sectors: UInt64 = 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        for (i, b) in [0x4B, 0x44, 0x4D, 0x56].enumerated() { bytes[i] = UInt8(b) }
        func le(_ value: UInt64, _ at: Int, _ width: Int) {
            for i in 0..<width { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        le(1, 4, 4)  // version
        le(UInt64(flags), 8, 4)
        le(at, 28, 8)
        le(sectors, 36, 8)
        return Data(bytes)
    }

    let plain = SparseVmdkHeader.parse(header(flags: 3))
    expect("\(plain?.descriptorOffset ?? 0)", "1", "the descriptor is found inside the file")
    expect("\(plain?.descriptorSize ?? 0)", "20", "and so is its length")
    expect(plain?.streamed == false, "and an ordinary sparse image is not the streamed form")

    // Compressed grains, each behind a marker, which the sparse reader
    // identifies as the streamed form.
    expect(
        SparseVmdkHeader.parse(header(flags: 0x0003_0003))?.streamed == true,
        "compressed grains are recognised")
    expect(
        SparseVmdkHeader.parse(header(flags: 1 << 16))?.streamed == true,
        "so is compression on its own")

    var notSparse = [UInt8](repeating: 0, count: 512)
    notSparse[0] = 0x23  // '#', as a text descriptor begins
    expect(SparseVmdkHeader.parse(Data(notSparse)) == nil, "a text descriptor is not this")
    expect(SparseVmdkHeader.parse(Data(repeating: 0, count: 16)) == nil, "nor is a short read")
}

group("aVhdxSaysWhetherItWasClosedCleanly") {
    // Of the two headers the live one carries the higher sequence number. What
    // is read from it here is the log: one that is not empty means the image's
    // most recent state was never written back into the file.
    func header(sequence: UInt64, dirty: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: VhdxHeader.headerLength)
        for (i, b) in VhdxHeader.headerSignature.enumerated() { bytes[i] = b }
        for i in 0..<8 { bytes[8 + i] = UInt8((sequence >> (8 * UInt64(i))) & 0xFF) }
        if dirty { bytes[48] = 0x01 }
        return Data(bytes)
    }

    // The second header counted higher, so it decides, although the first one
    // is clean.
    let live = VhdxHeader.parse(headers: [
        header(sequence: 1, dirty: false),
        header(sequence: 2, dirty: true),
    ])
    expect(live?.dirty == true, "the header that counted higher decides")
    expect("\(live?.sequence ?? 0)", "2", "and it is the one that counted higher")

    let other = VhdxHeader.parse(headers: [
        header(sequence: 9, dirty: false),
        header(sequence: 2, dirty: true),
    ])
    expect(other?.dirty == false, "and the same the other way round")

    // A block that is not a header is passed over rather than guessed at.
    expect(
        VhdxHeader.parse(headers: [
            Data(repeating: 0, count: VhdxHeader.headerLength),
            header(sequence: 3, dirty: false),
        ])?.sequence == 3,
        "a block that is not a header is passed over")
    expect(VhdxHeader.parse(headers: []) == nil, "and no headers at all is no answer")
}

group("aVhdxThatNamesAParent") {
    // A differencing VHDX holds only the changes from a disk it names, and this
    // app opens no image that names another file.
    func metadata(parent: Bool) -> Data {
        // The items sit well past the table listing them, as in a real one.
        var bytes = [UInt8](repeating: 0, count: 65536 + 64)
        for (i, b) in Array("metadata".utf8).enumerated() { bytes[i] = b }
        bytes[10] = 1  // one entry: a 16-bit count at 10, not at 8
        for (i, b) in VhdxHeader.fileParameters.enumerated() { bytes[32 + i] = b }
        let at = 65536
        for i in 0..<4 { bytes[32 + 16 + i] = UInt8((at >> (8 * i)) & 0xFF) }
        bytes[32 + 20] = 8  // length
        bytes[at] = 0x00
        bytes[at + 1] = 0x00
        bytes[at + 2] = 0x80  // block size, 8 MB
        bytes[at + 4] = parent ? 0x02 : 0x00
        return Data(bytes)
    }

    expect(VhdxHeader.namesAParent(metadata: metadata(parent: true)), "a parent is spotted")
    expect(!VhdxHeader.namesAParent(metadata: metadata(parent: false)), "and its absence")
    expect(
        !VhdxHeader.namesAParent(metadata: Data(repeating: 0, count: 64)),
        "and nonsense is not a parent")

    // The region table says where that metadata is.
    var table = [UInt8](repeating: 0, count: VhdxHeader.regionLength)
    for (i, b) in Array("regi".utf8).enumerated() { table[i] = b }
    table[8] = 1
    for (i, b) in VhdxHeader.metadataRegion.enumerated() { table[16 + i] = b }
    table[16 + 16 + 2] = 0x30  // offset 0x300000
    expect(
        "\(VhdxHeader.metadataAt(regionTable: Data(table)) ?? 0)", "3145728",
        "the region table says where the metadata is")
}

group("aDocumentWithRulesAndCodeInIt") {
    // SPECS.md is shown inside the app and contains both. The reader parsed
    // neither: a rule came out as a paragraph reading "---", and an indented
    // layout was reflowed into a sentence.
    let doc = """
        # Formats

        ---

        Four layers carry a disk image:

            file extension  ->  DiskFormat
                            ->  imago driver

        Text after it.

        ```
        brew install llvm lld
        ```
        """
    let blocks = MarkdownDocument.parse(doc)

    var rules = 0
    var code: [[String]] = []
    var paragraphs = 0
    for b in blocks {
        switch b {
        case .rule: rules += 1
        case .code(let lines): code.append(lines)
        case .paragraph: paragraphs += 1
        default: break
        }
    }
    expect("\(rules)", "1", "a rule is a rule, not a paragraph of dashes")
    expect("\(code.count)", "2", "the indented block and the fenced one both come through")
    expect(
        code.first?.count == 2, "the indented block keeps both of its lines")
    expect(
        code.first?.first?.hasSuffix("DiskFormat") == true,
        "and keeps them as written rather than joining them")
    expect(code.last == ["brew install llvm lld"], "a fenced block is taken whole")
    expect("\(paragraphs)", "2", "the prose around them is still prose")
}

group("leftoverEngineHelpersAreTakenDown") {
    // The set arithmetic is the whole of the safety here: a helper that was
    // already running belongs to a drive somebody has open, and killing it
    // would take that drive down with it.
    let before: Set<Int32> = [10, 11]
    let now: Set<Int32> = [10, 11, 12, 13]
    expect(
        now.subtracting(before) == [12, 13],
        "only what this attempt started is taken down")
    expect(
        now.subtracting(now).isEmpty,
        "an attempt that started nothing takes nothing down")

    // Our own engine, not another copy of the app and not Homebrew's. The
    // match is on the directory the running bundle's engine lives in.
    let ours = "/Applications/Lukotta.app/Contents/Resources/engine/anylinuxfs"
    let mine = "\(ours)/libexec/gvproxy --listen unix:///tmp/network-abc.sock"
    let theirs = "/opt/homebrew/opt/anylinuxfs/libexec/gvproxy --listen unix:///tmp/n.sock"
    expect(mine.contains(ours), "a helper from this bundle is recognised")
    expect(!theirs.contains(ours), "and one from another engine is left alone")
}

group("theVolumeListingIsReadTheSameWayByBothReaders") {
    // Two readers take apart the engine's `list --decrypt` output: the Swift
    // parser, which offers the volumes, and the awk inside the mount script,
    // which decides what actually gets mounted. Neither had been run against a
    // listing shaped differently from the one captured from a real drive, and
    // both counted fields from the end.
    //
    // Captured from anylinuxfs 0.19.0. If the engine in vendor/engine.lock has
    // moved past what Diagnosis.enginesChecked names, capture it again: this
    // fixture is only worth what its resemblance to the real thing is.
    let captured = """
        lvm:fedoravg (volume group):
           #:            TYPE NAME             SIZE       IDENTIFIER
           0:     LVM2_scheme                  +0.9 GB    fedoravg
           1:           btrfs FEDORAROOT       252.0 MB   fedoravg:disk5s1:root
           2:           btrfs                  252.0 MB   fedoravg:disk5s1:home
           3:            ext4 My Backup Disk   376.0 MB   fedoravg:disk5s1:backup
           4:           btrfs SINGLETOKEN      376MB      fedoravg:disk5s1:spare
        """

    let lvs = VolumeGroupParser.logicalVolumes(in: captured)
    expect(lvs.count == 4, "four mountable volumes; the scheme row is not one")
    expect(
        lvs.map(\.identifier) == [
            "fedoravg:disk5s1:root", "fedoravg:disk5s1:home",
            "fedoravg:disk5s1:backup", "fedoravg:disk5s1:spare",
        ], "every identifier is read")
    expect(lvs[0].size == "252.0 MB", "a size of two fields")
    expect(lvs[1].label == "home", "a volume with no label falls back to its own name")
    expect(lvs[2].label == "My Backup Disk", "a label of several words is kept whole")
    expect(lvs[2].size == "376.0 MB", "and does not eat into the size")
    expect(lvs[3].size == "376MB", "a size of one field is read as the size")
    expect(lvs[3].label == "SINGLETOKEN", "and does not shift the label")

    // The awk itself, run over the same listing, since it is what decides what
    // is mounted and nothing else can check it.
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lukotta-listing-\(getpid()).txt")
    try? captured.write(to: temp, atomically: true, encoding: .utf8)
    let awk = Process()
    awk.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    awk.arguments = [
        "-v", "s=/run/EXPORT", "-v", "q='", "-v", "ro=-o ro ",
        MountScript.volumeAction, temp.path,
    ]
    let pipe = Pipe()
    awk.standardOutput = pipe
    awk.standardError = FileHandle.nullDevice
    try? awk.run()
    let out =
        String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    awk.waitUntilExit()
    try? FileManager.default.removeItem(at: temp)

    expect(awk.terminationStatus == 0, "the generated awk runs")
    expect(
        out.contains(
            "nfs_export_subdirs = [\"FEDORAROOT\", \"home\", \"My-Backup-Disk\", \"SINGLETOKEN\"]"),
        "every volume is exported under a name taken from its label")
    expect(!out.contains("btrfs"), "the type is never mistaken for part of a name")
    expect(!out.contains("376MB"), "nor a size for one")
    for lv in ["root", "home", "backup", "spare"] {
        expect(out.contains("/dev/fedoravg/\(lv)") || lv == "root", "\(lv) is mounted")
    }
    expect(
        out.contains("mount -o bind \"$ALFS_VM_MOUNT_POINT\" /run/EXPORT/FEDORAROOT"),
        "the first volume is the one the engine already mounted")
    expect(out.contains("mount -o remount,ro /run/EXPORT"), "the scratch export stays read-only")
}

group("aDriveOwnsOnlyItsOwnMounts") {
    // "disk4s1" is contained in "disk4s10", so asking plainly whether the
    // identifier appears reported the tenth partition's mount against the
    // first, and closed the wrong one.
    func drive(_ id: String) -> Drive {
        Drive(
            id: id, devicePath: "/dev/" + id, name: "", sizeBytes: 0,
            connection: "", kind: .microsoft, uuid: "")
    }
    let first = drive("disk4s1")
    expect(first.owns("/dev/disk4s1"), "its own device path")
    expect(first.owns("lvm:vg:disk4s1:root"), "and its own volume inside a container")
    expect(!first.owns("/dev/disk4s10"), "but not the tenth partition")
    expect(!first.owns("lvm:vg:disk4s10:root"), "nor a volume inside it")
    expect(!first.owns("/dev/disk14s1"), "nor a partition of another disk")

    // A whole disk still recognises the mounts of the partitions on it: a
    // letter may follow where a digit may not.
    expect(drive("disk4").owns("/dev/disk4s1"), "a whole disk owns its partitions")
    expect(!drive("disk4").owns("/dev/disk41s1"), "but not the forty-first disk")
    expect(!drive("").owns("/dev/disk4s1"), "and a drive with no identifier owns nothing")
}

group("theVolumeNoticeNeedsMoreThanOneVolume") {
    // The sentence the count feeds says "volumes", and no translation of it
    // varies by number, so a single volume that failed to open read as "This
    // drive holds 1 volumes".
    //
    // The marker carries "opened:total".
    func shortfall(_ opened: Int, of total: Int) -> Int? {
        MountScript.volumeShortfall(in: "\(MountScript.volumesMarker)\(opened):\(total)")
    }
    expect(shortfall(0, of: 1) == nil, "one volume that did not open says nothing")
    expect(shortfall(1, of: 3) == 3, "three volumes with one opened names all three")
    expect(shortfall(2, of: 2) == nil, "nothing is said when they all opened")
    expect(shortfall(3, of: 2) == nil, "nor when more opened than were found")
    expect(MountScript.volumeShortfall(in: "nothing here") == nil, "no marker, no notice")
    expect(
        MountScript.volumeShortfall(in: "\(MountScript.volumesMarker)one:two") == nil,
        "and a marker that is not two numbers is ignored")
}

group("aShortPassphraseIsRedactedToo") {
    // A passphrase of one or two characters is legal, and the engine is driven
    // through a pty, which echoes what is typed into it. Declining to redact a
    // short secret left exactly the shortest ones in the transcript that
    // reaches the screen, the log and a bug report.
    // None of these appear in the replacement itself, which contains the
    // letters of "redacted" and would otherwise be mistaken for a survival.
    for secret in ["q", "xy", "zzz", "hunter2"] {
        let transcript = "ALFS_PASSPHRASE echoed: \(secret)\nmounted /dev/disk4s1\n"
        let clean = Diagnostics.redact(transcript, secret: secret)
        expect(
            !clean.contains(secret),
            "a passphrase of \(secret.count) characters does not survive redaction")
        expect(clean.contains("[redacted]"), "and something says it was there")
    }

    // Replacing the exact secret cannot touch anything else, whatever its
    // length: the rest of the line is left as it was.
    let kept = Diagnostics.redact("mounting q: ok", secret: "q")
    expect(kept.contains("mounting"), "the words around it are untouched")
    expect(kept.contains("ok"), "including what follows")

    // Nothing to redact is not the same as everything to redact.
    expect(
        Diagnostics.redact("mounted", secret: "") == "mounted",
        "an empty secret redacts nothing")
    expect(
        Diagnostics.redact("mounted", secret: "   ") == "mounted",
        "and neither does one that is only spaces")
}

group("bitlockerPartWayThroughIsExplained") {
    // cryptsetup stops before touching a BitLocker volume whose recorded state
    // is anything but normal, which is what a drive Windows is still
    // encrypting or decrypting looks like. Nothing is written to one, so the
    // only thing owed is an explanation.
    let said = """
        Command failed with code -1: This BITLK device is in an unsupported \
        state and cannot be activated.
        """
    expect(
        Diagnosis.rule(for: said)?.name == "bitlocker-mid-conversion",
        "a drive part-way through conversion is recognised")
    expect(
        Diagnosis.rule(for: said)?.message().contains("let BitLocker finish") == true,
        "and the remedy is to let Windows finish")

    // And it does not swallow the volume that is simply not BitLocker.
    expect(
        Diagnosis.rule(for: "Device /dev/disk4s1 is not a valid BITLK device.")?.name
            == "not-bitlocker",
        "a partition that is not BitLocker is still reported as that")
}

group("whatWasOpenIsRememberedForNextTime") {
    MountMemory.forgetAll()
    expect(MountMemory.all().isEmpty, "nothing is remembered to begin with")

    MountMemory.remember(
        MountMemory.Entry(uuid: "UUID-1", readOnly: false, name: "Elements"))
    MountMemory.remember(
        MountMemory.Entry(
            uuid: "/Users/someone/backup.vdi", imagePath: "/Users/someone/backup.vdi",
            readOnly: true, name: "backup"))
    expect(MountMemory.all().count == 2, "both are remembered")
    expect(
        MountMemory.all().first { $0.uuid == "/Users/someone/backup.vdi" }?.readOnly == true,
        "and one opened read-only is remembered as read-only")

    // The same volume opened again replaces the earlier record rather than
    // being remembered twice, which would put it back twice at login.
    MountMemory.remember(
        MountMemory.Entry(uuid: "UUID-1", readOnly: true, name: "Elements"))
    expect(MountMemory.all().count == 2, "opening the same volume again replaces its record")
    expect(
        MountMemory.all().first { $0.uuid == "UUID-1" }?.readOnly == true,
        "with what it was opened as this time")

    // Ejecting is the person saying they are done with it.
    MountMemory.forget(uuid: "UUID-1")
    expect(MountMemory.all().count == 1, "ejecting one forgets that one")
    expect(
        MountMemory.all().first?.uuid == "/Users/someone/backup.vdi",
        "and leaves the other alone")

    MountMemory.forgetAll()
    expect(MountMemory.all().isEmpty, "and everything can be forgotten at once")

    // Off unless it is turned on: nothing is put back for anyone who has not
    // asked for it.
    UserDefaults.standard.removeObject(forKey: RestorePreference.key)
    expect(!RestorePreference.isOn, "putting drives back is off by default")
}

group("aFallbackToReadOnlySaysWhy") {
    // A drive that will not take writes is mounted read-only rather than left
    // closed. Before the fallback existed the mount failed and the reason was
    // stated; afterwards the drive opens and the reason has to come from the
    // same place, or the person is left with a drive that quietly refuses
    // writes and nothing to act on.
    let hibernated = """
        ntfs-3g: Windows is hibernated, refused to mount.
        LUKOTTA_STAGE:read-only
        """
    expect(
        Diagnosis.rule(for: hibernated)?.name == "windows-hibernated",
        "a hibernated volume is recognised in the transcript of a fallback")
    expect(
        Diagnosis.rule(for: hibernated)?.message().contains("Fast Startup") == true,
        "and the remedy names the setting to change")

    // Nothing invented where nothing is known: a transcript no rule matches
    // gives no reason at all, rather than the engine's last line, which beside
    // a drive that did open would read as a fault.
    let quiet = "mounted /dev/disk4s1\nLUKOTTA_STAGE:read-only\n"
    expect(
        Diagnosis.rule(for: quiet) == nil,
        "a transcript with nothing to say produces no explanation")
}

group("theMarkerCannotFireAfterAWritableMount") {
    // `||` and `&&` have equal precedence in the shell and group left to
    // right, so `a || { b ; } && echo m` runs the echo when `a` succeeded.
    // Written that way, every mount that succeeded read-write reported
    // itself as read-only, and the drive was marked in the list as
    // something it was not.
    let shape = { (script: String) -> String in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    expect(
        shape("true || { true ; } && echo marker").contains("marker"),
        "the shape that was wrong does fire the marker after a writable mount")
    expect(
        !shape("true || { true && echo marker ; }").contains("marker"),
        "and the shape used instead does not")
    expect(
        shape("false || { true && echo marker ; }").contains("marker"),
        "while a mount that had to fall back still says so")

    // And the script itself is the second shape.
    let script = MountScript.build(sampleInputs())
    expect(
        !script.contains("; } && echo"),
        "the generated script keeps each marker inside the attempt it belongs to")
    expect(
        script.contains("&& echo \"\(MountScript.stageMarker)read-only\""),
        "and still marks a mount that fell back")
}

group("readOnlyIsBothSidesOfTheConnection") {
    // The export stops the host writing and `-o ro` makes the mount inside the
    // guest read-only underneath it. Either alone leaves one side able to
    // write, so both are asserted here.
    let script = MountScript.build(sampleInputs(readOnly: true))
    expect(script.contains(" -o ro"), "the guest mounts the filesystem read-only")

    // The host side is the export, named in the one flag the engine accepts
    // alongside a read-only mount. Asked for in the NFS options instead, the
    // engine builds that flag itself and then refuses its own combination.
    expect(
        !script.contains("readahead=128,ro"),
        "the NFS options do not ask for it, which is what the engine refuses")
    expect(script.contains("--nfs-export-opts="), "the export says so instead")

    // Every attempt, not merely the first: the ntfs-3g retry and the LVM
    // discovery must not quietly mount a drive read-write after the read-only
    // attempt failed.
    let attempts = script.components(separatedBy: "anylinuxfs' mount").dropFirst()
    expect(!attempts.isEmpty, "there is more than one attempt to check")
    expect(
        attempts.allSatisfy { $0.contains("-o ro") },
        "and every one of them asks for read-only")

    let linux = MountScript.build(sampleInputs(kind: .linux, readOnly: true))
    expect(
        linux.contains("-v ro='-o ro '"),
        "the generated multi-volume action mounts each volume read-only")

    // Asking for read-only means read-only throughout: no attempt in the chain
    // may fall back to a writable mount.
    expect(
        !script.contains("LUKOTTA_STAGE:read-only"),
        "a mount asked for read-only needs no marker, being read-only from the start")

    // A read-write mount tries read-write first and only then read-only, so the
    // order in the chain is what makes the fallback a fallback.
    let plain = MountScript.build(sampleInputs())
    let firstRO = plain.range(of: "-o ro").map {
        plain.distance(from: plain.startIndex, to: $0.lowerBound)
    }
    let firstRW = plain.range(of: "mount --ignore-permissions").map {
        plain.distance(from: plain.startIndex, to: $0.lowerBound)
    }
    expect(firstRO != nil, "a read-write mount carries read-only attempts after its own")
    expect(
        (firstRW ?? 0) < (firstRO ?? 0),
        "and tries writable first, so read-only is reached only when that fails")
    expect(
        plain.contains("LUKOTTA_STAGE:read-only"),
        "a fallback that succeeds says so, so the drive is never called writable when it is not")

    // And the host's own mount is marked afterwards, which is the half Finder
    // reads. Both sides behind the NFS server are read-only, so the volume
    // arrived here presented as writable and refused a write at the moment one
    // was made rather than when it was opened.
    expect(
        script.contains("/sbin/mount -u -o ro"),
        "and the mount somebody sees is updated to say read-only")
    expect(
        plain.contains("grep -q \"LUKOTTA_STAGE:read-only\""),
        "a read-write mount marks it only where the fallback was what opened it")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("PASS: LukottaCore")
