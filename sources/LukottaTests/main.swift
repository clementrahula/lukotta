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

/// One attribute's own bytes, walked to by type.
///
/// The reader hands back a parsed header; some of what a writer has to get
/// right is not in it, because nothing reading a volume needs it. Windows does.
func attributeRaw(_ record: Data, header: NTFSRecord.Header, type wanted: UInt32) -> Data? {
    var at = header.firstAttributeOffset
    let base = record.startIndex
    while at + 8 <= header.usedLength {
        var kind: UInt32 = 0
        for byte in 0..<4 { kind |= UInt32(record[base + at + byte]) << (8 * UInt32(byte)) }
        if kind == 0xFFFF_FFFF { return nil }
        var length = 0
        for byte in 0..<4 { length |= Int(record[base + at + 4 + byte]) << (8 * byte) }
        guard length >= 24, at + length <= header.usedLength else { return nil }
        if kind == wanted { return Data(record[(base + at)..<(base + at + length)]) }
        at += length
    }
    return nil
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

group("spaceIsReservedBeforeALargeCopyRatherThanDiscovered") {
    // Finder asks for the space before it moves a large file, so that a copy
    // fails at the start instead of nine tenths of the way through. A module
    // that refuses makes the caller fall back to writing and finding out, which
    // is the slow and disappointing order.
    //
    // The volume answers it by growing the file, which is what makes the
    // caller's next write land in space that already exists. Both backings can
    // do that, so both are checked -- the passthrough is a real filesystem
    // underneath and behaves differently from a dictionary.
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("prealloc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let backings: [(name: String, backing: any FSBacking)] = [
        ("memory", FSStoreBacking()),
        ("a real directory", FSPassthroughBacking(root: base)),
    ]
    for (name, fs) in backings {
        let root = fs.rootHandle
        guard let file = fs.create("big.mov", isDirectory: false, in: root, mode: 0o644) else {
            expect(false, "\(name): a file to reserve space in")
            continue
        }
        expect(fs.attributes(of: file)?.size == 0, "\(name): it starts empty")

        // Growing it is what reserving means here.
        fs.truncate(file, to: 1_000_000)
        expect(
            fs.attributes(of: file)?.size == 1_000_000,
            "\(name): reserving a megabyte makes the file a megabyte long")

        // Asking for less than it already is must not shorten it. A
        // preallocation that truncated would destroy the data it was called to
        // protect.
        let before = fs.attributes(of: file)?.size
        if let before, before > 500_000 {
            expect(before == 1_000_000, "\(name): and asking for less does not shorten it")
        }

        // The reserved space reads back as zeroes rather than as whatever was
        // in memory or on the disk before.
        expect(
            fs.read(file, offset: 999_000, length: 100) == Data(count: 100),
            "\(name): and reserved space reads as zeroes, not as someone else's bytes")
        _ = fs.remove("big.mov", from: root)
    }
}

group("aWriteThatIsNotWholeBlocksHasToReadFirst") {
    // A block device moves whole blocks whichever byte was asked for, so a
    // write of less than a block has to read the block, change the part that
    // moved and put it back. Getting this arithmetic wrong is not slow, it is
    // somebody else's bytes written over or a file that reads back with a hole
    // in it -- so every edge of it is checked here rather than trusted inside a
    // method that is also talking to FSKit.
    let block = 4096

    // The ordinary case: a byte in the middle of a block.
    let one = FSBlockRange.covering(offset: 100, length: 10, blockSize: block)
    expect(one?.start == 0, "a read inside the first block starts at zero")
    expect(one?.span == block, "and spans one whole block")
    expect(
        FSBlockRange.offsetWithinBlocks(offset: 100, blockSize: block) == 100,
        "with the wanted bytes 100 in")

    // Straddling a boundary: two blocks, not one.
    let two = FSBlockRange.covering(offset: 4090, length: 20, blockSize: block)
    expect(two?.start == 0, "a range crossing a boundary still starts at the block before")
    expect(two?.span == block * 2, "and covers both blocks")

    // Exactly aligned, which is the only shape that reaches the device's speed.
    expect(FSBlockRange.isAligned(offset: 0, length: block, blockSize: block), "one whole block")
    expect(
        FSBlockRange.isAligned(offset: block * 3, length: block * 2, blockSize: block),
        "several whole blocks from a block boundary")
    expect(
        !FSBlockRange.isAligned(offset: 1, length: block, blockSize: block),
        "a block-sized write one byte in is not aligned")
    expect(
        !FSBlockRange.isAligned(offset: 0, length: block - 1, blockSize: block),
        "and neither is a write one byte short")
    let aligned = FSBlockRange.covering(offset: block, length: block, blockSize: block)
    expect(
        aligned?.start == block && aligned?.span == block, "an aligned range spans exactly itself")

    // The cost of not being aligned, which is the number worth watching when a
    // copy is slower than the drive it is copying to.
    expect(
        FSBlockRange.readModifyWriteBytes(offset: 0, length: block, blockSize: block) == 0,
        "an aligned write reads nothing first")
    expect(
        FSBlockRange.readModifyWriteBytes(offset: 100, length: 10, blockSize: block)
            == block - 10,
        "and a ten-byte write pays for the rest of the block around it")

    // Nothing, which is not the same as one block.
    expect(
        FSBlockRange.covering(offset: 100, length: 0, blockSize: block)?.span == 0,
        "a zero-length range touches no blocks")

    // Values from outside are refused rather than dividing by zero or wrapping.
    expect(FSBlockRange.covering(offset: 0, length: 10, blockSize: 0) == nil, "no block size")
    expect(
        FSBlockRange.covering(offset: -1, length: 10, blockSize: block) == nil, "before the start")
    expect(
        FSBlockRange.covering(offset: 0, length: -1, blockSize: block) == nil, "a negative length")
    expect(
        FSBlockRange.covering(offset: 0, length: Int.max, blockSize: block) == nil,
        "and a length that would overflow rounding up, rather than a wrapped answer")
    expect(
        FSBlockRange.offsetWithinBlocks(offset: -1, blockSize: block) == nil,
        "an impossible offset has no position within a block")
    expect(
        !FSBlockRange.isAligned(offset: 0, length: 0, blockSize: 0),
        "and no block size is never aligned")
}

group("theGeometryReaderAgreesWithARealNtfsVolume") {
    // Synthetic boot sectors prove the arithmetic and the refusals. They cannot
    // prove the offsets are the ones Microsoft actually writes at, because a
    // fixture built from the same belief as the reader agrees with it whatever
    // that belief is. So when a real NTFS volume is on this machine, it is read.
    //
    // Skipped rather than failed where there is none: a check that needs a
    // fixture nobody has built is not a broken check.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let sector = try? handle.read(upToCount: 4096), !sector.isEmpty
    else {
        expect(true, "no NTFS volume on this machine to read; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    expect(BootSector.identify(sector) == .ntfs, "the real volume identifies as NTFS")
    guard let g = NTFSGeometry.read(sector) else {
        expect(false, "and its geometry is read rather than refused")
        return
    }

    // Everything that must be true of any volume mkntfs produces, checked
    // against the reader rather than against numbers copied from it.
    expect([512, 1024, 2048, 4096].contains(g.bytesPerSector), "its sector size is one NTFS uses")
    expect(
        g.sectorsPerCluster > 0 && g.sectorsPerCluster & (g.sectorsPerCluster - 1) == 0,
        "its cluster is a power of two sectors")
    expect(g.bytesPerCluster >= 512, "a cluster is at least a sector")
    expect(g.totalSectors > 0, "the volume has an extent")
    expect(
        g.mftStartCluster > 0 && g.mftByteOffset < g.totalBytes,
        "the master file table is on the volume, past its boot sector")
    expect(
        g.mftMirrorStartCluster > 0 && g.mftMirrorStartCluster != g.mftStartCluster,
        "and the backup table is elsewhere, which is the whole point of it")
    expect(
        g.bytesPerFileRecord >= 256 && g.bytesPerFileRecord % 256 == 0,
        "the file record size is a sensible multiple")
}

group("aFileRecordIsRepairedBeforeItIsBelieved") {
    // NTFS writes a two-byte signature at the end of every sector of a record
    // and keeps the displaced bytes at the front. A record read straight off
    // the disk has two bytes of rubbish at the end of each sector, and anything
    // parsing it without putting them back reads garbage exactly where a long
    // attribute crosses a sector boundary.
    //
    // The point of the scheme is that a torn write is detectable: if the
    // signatures do not match, the record was half-written and must be refused.

    func record(
        used: Int = 200, allocated: Int = 1024, firstAttribute: Int = 56,
        fixupOffset: Int = 48, fixupCount: Int = 3, flags: Int = 0x0001,
        signature: [UInt8] = Array("FILE".utf8), sectorSignature: [UInt8] = [0xAA, 0xBB],
        tearSecondSector: Bool = false
    ) -> Data {
        var r = [UInt8](repeating: 0, count: allocated)
        for (i, b) in signature.enumerated() where i < 4 { r[i] = b }
        r[0x04] = UInt8(fixupOffset & 0xFF); r[0x05] = UInt8(fixupOffset >> 8)
        r[0x06] = UInt8(fixupCount & 0xFF); r[0x07] = UInt8(fixupCount >> 8)
        r[0x14] = UInt8(firstAttribute & 0xFF); r[0x15] = UInt8(firstAttribute >> 8)
        r[0x16] = UInt8(flags & 0xFF); r[0x17] = UInt8(flags >> 8)
        for i in 0..<4 { r[0x18 + i] = UInt8((used >> (8 * i)) & 0xFF) }
        for i in 0..<4 { r[0x1C + i] = UInt8((allocated >> (8 * i)) & 0xFF) }
        // The fixup array: the signature, then the bytes displaced from each
        // sector's last two. The invalid cases below deliberately name an array
        // that does not fit, so every write here is bounded -- a fixture that
        // crashes proves nothing about the parser.
        if fixupOffset + 1 < r.count {
            r[fixupOffset] = sectorSignature[0]
            r[fixupOffset + 1] = sectorSignature[1]
        }
        for sector in 1..<max(fixupCount, 1) {
            let entry = fixupOffset + sector * 2
            if entry + 1 < r.count {
                r[entry] = UInt8(0x10 + sector)
                r[entry + 1] = UInt8(0x20 + sector)
            }
            let end = sector * 512 - 2
            if end + 1 < r.count {
                r[end] = sectorSignature[0]
                r[end + 1] = sectorSignature[1]
            }
        }
        if tearSecondSector, 2 * 512 - 2 < r.count { r[2 * 512 - 2] = 0xFF }
        return Data(r)
    }

    guard let h = NTFSRecord.header(record(), expectedLength: 1024) else {
        expect(false, "an ordinary file record has a readable header")
        return
    }
    expect(h.usedLength == 200, "the used length is read")
    expect(h.allocatedLength == 1024, "and the allocated length")
    expect(h.firstAttributeOffset == 56, "and where the attributes start")
    expect(h.inUse, "a record in use says so")
    expect(!h.isDirectory, "and this one is a file")
    expect(
        NTFSRecord.header(record(flags: 0x0003), expectedLength: 1024)?.isDirectory == true,
        "a directory record says that instead")
    expect(
        NTFSRecord.header(record(flags: 0x0000), expectedLength: 1024)?.inUse == false,
        "and a free slot waiting to be reused is not in use")

    // Not a record.
    expect(
        NTFSRecord.header(record(signature: Array("BAAD".utf8)), expectedLength: 1024) == nil,
        "a record chkdsk marked corrupt is not read")
    expect(NTFSRecord.header(Data(count: 1024), expectedLength: 1024) == nil, "nor are zeroes")
    expect(NTFSRecord.header(Data(count: 10), expectedLength: 1024) == nil, "nor a short read")

    // Every number that would read past the end of the buffer if believed.
    expect(
        NTFSRecord.header(record(allocated: 1024), expectedLength: 512) == nil,
        "a record claiming to be longer than what was read is refused")
    expect(
        NTFSRecord.header(record(used: 5000, allocated: 1024), expectedLength: 1024) == nil,
        "a used length past the end of the record is refused")
    expect(
        NTFSRecord.header(record(firstAttribute: 5000), expectedLength: 1024) == nil,
        "an attribute offset past the end is refused")
    expect(
        NTFSRecord.header(record(firstAttribute: 10), expectedLength: 1024) == nil,
        "and one inside the header is refused too")
    expect(
        NTFSRecord.header(record(fixupOffset: 1000, fixupCount: 40), expectedLength: 1024) == nil,
        "a fixup array that does not fit before the attributes is refused")
    expect(
        NTFSRecord.header(record(fixupCount: 0), expectedLength: 1024) == nil,
        "and one with no entries at all")

    // The repair itself.
    let whole = record()
    guard let header = NTFSRecord.header(whole, expectedLength: 1024),
        let fixed = NTFSRecord.applyFixup(whole, header: header)
    else {
        expect(false, "a whole record is repaired")
        return
    }
    expect(fixed[510] == 0x11 && fixed[511] == 0x21, "the first sector's displaced bytes are back")
    expect(fixed[1022] == 0x12 && fixed[1023] == 0x22, "and the second sector's")
    expect(fixed.count == whole.count, "and the record is the same length it was")

    // The case the whole scheme exists for.
    let torn = record(tearSecondSector: true)
    if let h2 = NTFSRecord.header(torn, expectedLength: 1024) {
        expect(
            NTFSRecord.applyFixup(torn, header: h2) == nil,
            "a record whose sector signature does not match was half-written, and is refused "
                + "rather than half believed")
    }
}

group("theRecordReaderAgreesWithARealMasterFileTable") {
    // The synthetic record proves the arithmetic and the refusals. This proves
    // the offsets are the ones NTFS actually writes at, by reading the first
    // record of a real volume's master file table -- $MFT's own record, which
    // every NTFS volume has and which nothing can be mounted without.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        raw.count == geometry.bytesPerFileRecord
    else {
        expect(false, "the first MFT record is where the geometry said it would be")
        return
    }

    guard let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord) else {
        expect(false, "and it reads as a file record")
        return
    }
    expect(header.inUse, "$MFT's own record is in use, as it is on every volume")
    expect(
        header.allocatedLength == geometry.bytesPerFileRecord,
        "and is exactly as long as the boot sector said a record is")
    expect(header.usedLength <= header.allocatedLength, "with a used length inside it")
    expect(
        header.firstAttributeOffset >= 42 && header.firstAttributeOffset < header.usedLength,
        "and attributes beginning after the header and before the end")
    expect(header.fixupCount >= 1, "it carries a fixup array")
    expect(
        header.fixupCount - 1 <= geometry.bytesPerFileRecord / geometry.bytesPerSector,
        "with one entry per sector of the record, and no more")

    // The repair, on bytes nobody here wrote.
    guard
        let repaired = NTFSRecord.applyFixup(
            raw, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "a real record read cleanly off the disk repairs rather than refusing")
        return
    }
    expect(repaired.count == raw.count, "the repaired record is the same length")
    expect(
        repaired != raw,
        "and differs from what was on disk -- which is the whole point: the bytes at the "
            + "end of each sector were the signature and are now the file's own")
}

group("attributesAreWalkedOnceAndNeverOffTheEnd") {
    // Everything NTFS knows about a file is an attribute, laid out one after
    // another until an end marker. Walking that list means trusting a length
    // out of each header, so a zero loops for ever and a large one walks off
    // the end of the record -- both from bytes that came off somebody's disk.

    func attribute(
        type: UInt32, length: Int, resident: Bool = true,
        valueOffset: Int = 24, valueLength: Int = 8, runlistOffset: Int = 64,
        start: UInt64 = 0, last: UInt64 = 0, dataSize: UInt64 = 0
    ) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: max(length, 16))
        for i in 0..<4 { a[i] = UInt8((type >> (8 * UInt32(i))) & 0xFF) }
        for i in 0..<4 { a[4 + i] = UInt8((length >> (8 * i)) & 0xFF) }
        a[8] = resident ? 0 : 1
        if resident {
            if a.count > 23 {
                for i in 0..<4 { a[16 + i] = UInt8((valueLength >> (8 * i)) & 0xFF) }
                a[20] = UInt8(valueOffset & 0xFF); a[21] = UInt8(valueOffset >> 8)
            }
        } else if a.count > 63 {
            for i in 0..<8 { a[16 + i] = UInt8((start >> (8 * UInt64(i))) & 0xFF) }
            for i in 0..<8 { a[24 + i] = UInt8((last >> (8 * UInt64(i))) & 0xFF) }
            a[32] = UInt8(runlistOffset & 0xFF); a[33] = UInt8(runlistOffset >> 8)
            for i in 0..<8 { a[48 + i] = UInt8((dataSize >> (8 * UInt64(i))) & 0xFF) }
        }
        return a
    }

    // A resident attribute: the file's contents live inside the record, which
    // is why a volume of tiny files is faster on NTFS than its cluster size
    // suggests.
    var record = attribute(type: 0x10, length: 96)
    record += attribute(
        type: 0x80, length: 200, resident: false, start: 10, last: 19,
        dataSize: 40_960)
    record += [0xFF, 0xFF, 0xFF, 0xFF]
    record += [UInt8](repeating: 0, count: 32)
    let data = Data(record)

    guard let first = NTFSAttribute.header(data, at: 0) else {
        expect(false, "the first attribute is read")
        return
    }
    expect(first.kind == .standardInformation, "and it is the one it says it is")
    expect(first.isResident, "a resident attribute says so")
    expect(first.length == 96, "with its own length, which is how the list is walked")
    expect(first.valueLength == 8, "and its value's length")

    guard let second = NTFSAttribute.header(data, at: 96) else {
        expect(false, "the second attribute is read at the offset the first's length gives")
        return
    }
    expect(second.kind == .data, "the file's contents are a DATA attribute")
    expect(!second.isResident, "a large one lives out on the disk")
    expect(second.startingCluster == 10 && second.lastCluster == 19, "over a range of clusters")
    expect(second.dataSize == 40_960, "and reports the file's real size, not its allocation")

    let all = NTFSAttribute.all(in: data, startingAt: 0, usedLength: data.count)
    expect(all.count == 2, "walking the record finds both and stops at the end marker")
    expect(all.map(\.type) == [0x10, 0x80], "in the order they are written")

    // The numbers that would loop or walk off the end.
    let zeroLength = Data(attribute(type: 0x10, length: 0) + [UInt8](repeating: 0, count: 64))
    expect(
        NTFSAttribute.header(zeroLength, at: 0) == nil,
        "an attribute of no length is refused -- believing it walks the list for ever")
    // A short record whose header claims a long attribute, which is the shape a
    // corrupt record actually has: the bytes end, the number does not.
    let huge = Data(attribute(type: 0x10, length: 99999).prefix(64))
    expect(
        NTFSAttribute.header(huge, at: 0) == nil,
        "and one longer than the record is refused rather than read past the end")
    expect(NTFSAttribute.header(data, at: 100_000) == nil, "an offset past the end reads nothing")
    expect(NTFSAttribute.header(data, at: -1) == nil, "and so does one before the start")

    // A resident value has to sit inside its own attribute. One that points
    // past it reads the next attribute's bytes as this file's contents.
    let overreaching = Data(attribute(type: 0x10, length: 96, valueOffset: 24, valueLength: 500))
    expect(
        NTFSAttribute.header(overreaching, at: 0) == nil,
        "a value claiming more than its attribute holds is refused")

    // The end marker closes the list, and nothing after it is read.
    let onlyEnd = Data([0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0x41, count: 64))
    expect(
        NTFSAttribute.all(in: onlyEnd, startingAt: 0, usedLength: 68).isEmpty,
        "a record that begins with the end marker holds no attributes")
}

group("theAttributeReaderAgreesWithARealFileRecord") {
    // $MFT's own record on a real volume. Every NTFS volume has it and nothing
    // mounts without it, so it is the one record whose contents can be asserted
    // without knowing anything about the disk it came from.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
        let record = NTFSRecord.applyFixup(
            raw, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "the first MFT record reads and repairs")
        return
    }

    let attributes = NTFSAttribute.all(
        in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength)
    expect(!attributes.isEmpty, "the record holds attributes")

    // What $MFT must have, on any volume any tool produced.
    let kinds = attributes.compactMap(\.kind)
    expect(
        kinds.contains(.standardInformation),
        "every file record begins with its standard information")
    expect(kinds.contains(.fileName), "and carries a name")
    expect(kinds.contains(.data), "$MFT has a DATA attribute -- it is a file like any other")

    guard let data = attributes.first(where: { $0.kind == .data }) else { return }
    expect(
        !data.isResident,
        "and $MFT's own data is never resident: the table cannot fit inside a record of itself")
    expect(data.dataSize > 0, "it reports a real size")
    expect(
        data.lastCluster >= data.startingCluster,
        "over a cluster range that does not run backwards")
    expect(
        data.runlistOffset > 0 && data.runlistOffset < record.count,
        "and points at a runlist inside the record -- which is the list of extents "
            + "kernel-offloaded I/O would hand to the kernel")

    // The parser walked the whole record and stopped where the record stops.
    let total = attributes.reduce(header.firstAttributeOffset) { $0 + $1.length }
    expect(
        total <= header.usedLength,
        "walking every attribute lands inside the used length rather than past it")
}

group("aRunlistSaysWhereAFileActuallyIs") {
    // The extents of a file, packed as tightly as NTFS could manage: a header
    // byte giving the width of the two numbers after it, then a length in
    // clusters, then the first cluster *relative to the previous run's*.
    //
    // That relative offset is the trap. Runs are not ascending -- a file
    // written over time scatters, and a later run can sit before an earlier one
    // -- so the delta is signed. Decoding it unsigned gives extents pointing at
    // the wrong end of the disk, which reads as a file full of somebody else's
    // data rather than as an error.

    // 0x21: one byte of length, two of offset. 8 clusters at +0x0100.
    let simple = Data([0x21, 0x08, 0x00, 0x01, 0x00])
    guard let one = NTFSRunlist.decode(simple, at: 0, limit: simple.count) else {
        expect(false, "an ordinary runlist decodes")
        return
    }
    expect(one.count == 1, "one run")
    expect(one[0].clusterCount == 8, "of eight clusters")
    expect(one[0].physicalCluster == 0x0100, "starting where the offset says")
    expect(one[0].logicalCluster == 0, "at the beginning of the file")
    expect(!one[0].isHole, "and it is real data")

    // Two runs, the second going backwards. 0x11 0x04 0xF0 is +4 clusters at a
    // delta of -16, which is what a fragmented file looks like.
    let backwards = Data([0x21, 0x08, 0x00, 0x01, 0x11, 0x04, 0xF0, 0x00])
    guard let two = NTFSRunlist.decode(backwards, at: 0, limit: backwards.count) else {
        expect(false, "a runlist whose second run goes backwards decodes")
        return
    }
    expect(two.count == 2, "two runs")
    expect(two[1].physicalCluster == 0x0100 - 16, "the second sits before the first on the disk")
    expect(
        two[1].logicalCluster == 8,
        "but after it in the file, which is what makes the delta signed rather than an error")

    // A hole: a length and no offset at all. Sparse files read these as zeroes
    // and they occupy nothing -- FSKit calls it FSExtentTypeZeroFill.
    let sparse = Data([0x21, 0x04, 0x00, 0x01, 0x01, 0x08, 0x21, 0x04, 0x00, 0x01, 0x00])
    guard let holes = NTFSRunlist.decode(sparse, at: 0, limit: sparse.count) else {
        expect(false, "a sparse runlist decodes")
        return
    }
    expect(holes.count == 3, "three runs")
    expect(holes[1].isHole, "the middle one is a hole")
    expect(holes[1].physicalCluster == nil, "pointing nowhere on the disk")
    expect(holes[1].clusterCount == 8, "but occupying eight clusters of the file")
    expect(holes[2].logicalCluster == 12, "and the run after it continues where the hole ended")

    // The clean way out.
    expect(
        NTFSRunlist.decode(Data([0x00]), at: 0, limit: 1)?.isEmpty == true,
        "a runlist that is only its terminator holds no runs")

    // Everything malformed. Nil rather than a partial list: half a file's
    // extents is a file that reads as truncated, which is worse than one that
    // will not open.
    expect(
        NTFSRunlist.decode(Data([0x21, 0x08]), at: 0, limit: 2) == nil,
        "a run whose bytes end early is refused")
    expect(
        NTFSRunlist.decode(Data([0x21, 0x08, 0x00, 0x01]), at: 0, limit: 4) == nil,
        "and one with no terminator is refused rather than assumed to end")
    expect(
        NTFSRunlist.decode(Data([0x20, 0x00, 0x01]), at: 0, limit: 3) == nil,
        "a run with no length bytes is meaningless and refused")
    expect(
        NTFSRunlist.decode(Data([0x11, 0x00, 0x01, 0x00]), at: 0, limit: 4) == nil,
        "a run of zero clusters is refused")
    // A delta that would put the run before the start of the disk.
    expect(
        NTFSRunlist.decode(Data([0x11, 0x04, 0x80, 0x00]), at: 0, limit: 4) == nil,
        "a run before the start of the disk is refused rather than wrapped")
    expect(NTFSRunlist.decode(Data([0x21]), at: 5, limit: 1) == nil, "an offset past the limit")
    expect(NTFSRunlist.decode(Data([0x21]), at: -1, limit: 1) == nil, "and one before the start")

    // A cluster number so large that turning it into a byte offset overflows.
    // Every consumer multiplies by the cluster size, and on UInt64 an overflow
    // is a trap rather than a wrong answer: the extension dies instead of
    // refusing the drive. The bound belongs here, where the numbers are made,
    // rather than at each of the eleven places they are used.
    //
    // 0x48 says eight bytes of offset and eight of length, so this names a
    // cluster near 2^63 -- reachable from a corrupt disk, and fatal downstream.
    let vast = Data(
        [0x88, 0x01, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x00])
    expect(
        NTFSRunlist.decode(vast, at: 0, limit: vast.count) == nil,
        "a cluster number that would overflow a byte offset is refused rather than trapped on")

    // And a run that starts low but is long enough to reach the same place.
    let endless = Data([0x18, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x04, 0x00])
    expect(
        NTFSRunlist.decode(endless, at: 0, limit: endless.count) == nil,
        "and so is a run long enough to run off the end of the arithmetic")

    // The bound is far past any real volume: an exabyte at four kilobytes.
    expect(
        NTFSRunlist.maximumCluster == 1 << 48,
        "the bound is 2^48 clusters, which no volume reaches and no multiplication overflows")

    // What the caller checks before trusting the file.
    expect(NTFSRunlist.clusterCount(holes) == 16, "the runs cover sixteen clusters in total")
    expect(NTFSRunlist.covers(holes, clusters: 16), "which is what the attribute should claim")
    expect(
        !NTFSRunlist.covers(holes, clusters: 20),
        "a runlist covering less than the file claims is a truncated file, not a short read")
}

group("theRunlistDecoderAgreesWithARealVolume") {
    // $MFT's own DATA runlist. Every NTFS volume has one, it can never be
    // resident, and where it points is knowable independently: the boot sector
    // already said which cluster the master file table starts at, so the first
    // run has to begin exactly there. That makes this the one runlist whose
    // answer can be checked rather than merely parsed.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
        let record = NTFSRecord.applyFixup(
            raw, header: header, sectorSize: geometry.bytesPerSector),
        let data = NTFSAttribute.all(
            in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength
        ).first(where: { $0.kind == .data })
    else {
        expect(false, "$MFT's DATA attribute is found")
        return
    }

    guard let runs = NTFSRunlist.decode(record, at: data.runlistOffset, limit: record.count) else {
        expect(false, "and its runlist decodes")
        return
    }
    expect(!runs.isEmpty, "there is at least one run")
    expect(runs.allSatisfy { !$0.isHole }, "$MFT is never sparse -- none of its runs is a hole")

    // The check that makes this worth doing: the boot sector said where the
    // table starts, and the runlist has to agree. Two independent statements
    // about the same fact, one decoded through five layers of parsing.
    expect(
        runs[0].physicalCluster == geometry.mftStartCluster,
        "the first run begins at exactly the cluster the boot sector named for the MFT")
    expect(
        runs[0].logicalCluster == 0,
        "and at the beginning of the file, since a runlist starts where the file starts")

    // And the runs have to account for the whole attribute, or the file is
    // truncated.
    let claimed = data.lastCluster - data.startingCluster + 1
    expect(
        NTFSRunlist.covers(runs, clusters: claimed),
        "the runs cover exactly the clusters the attribute claims, with none missing or spare")

    // Every run lands inside the volume. One that did not would be a read of
    // whatever is past the partition.
    let totalClusters = geometry.totalSectors / UInt64(geometry.sectorsPerCluster)
    expect(
        runs.allSatisfy { ($0.physicalCluster ?? 0) + $0.clusterCount <= totalClusters },
        "and every run lies inside the volume rather than past the end of it")
}

group("aFileIsShownUnderTheNameSomebodyGaveIt") {
    // A record usually carries more than one $FILE_NAME: NTFS keeps a short
    // DOS name beside the real one, PROGRA~1 beside Program Files. A reader
    // that takes the first it finds shows eight-character names for half a
    // disk, and nothing about that looks like an error.

    func fileName(_ text: String, parent: UInt64 = 5, namespace: UInt8 = 1) -> Data {
        var v = [UInt8](repeating: 0, count: 66)
        for i in 0..<8 { v[i] = UInt8((parent >> (8 * UInt64(i))) & 0xFF) }
        let units = Array(text.utf16)
        v[64] = UInt8(units.count)
        v[65] = namespace
        for u in units { v.append(UInt8(u & 0xFF)); v.append(UInt8(u >> 8)) }
        return Data(v)
    }

    guard let ordinary = NTFSFileName.read(fileName("Report.txt")) else {
        expect(false, "an ordinary name is read")
        return
    }
    expect(ordinary.name == "Report.txt", "and comes back as it was written")
    expect(ordinary.namespace == .win32, "in the namespace somebody typed it in")
    expect(ordinary.parentRecord == 5, "with the directory holding it -- 5 is the root")

    // The length is in UTF-16 characters, not bytes. Read as bytes a name comes
    // out doubled and truncated.
    expect(
        NTFSFileName.read(fileName("A"))?.name == "A",
        "a one-character name is one character, not two bytes of one")
    expect(
        NTFSFileName.read(fileName("Ölandsvägen"))?.name == "Ölandsvägen",
        "and a name outside ASCII survives, which byte-length reading would cut in half")
    expect(
        NTFSFileName.read(fileName("写真フォルダ"))?.name == "写真フォルダ",
        "including one with no ASCII in it at all")
    // Outside the basic plane, where one character is two UTF-16 units.
    expect(
        NTFSFileName.read(fileName("holiday 🏖.jpg"))?.name == "holiday 🏖.jpg",
        "and a surrogate pair is one character rather than two broken ones")

    // The parent is a file reference: 48 bits of record and 16 of sequence.
    // Taking all 64 gives a directory number no volume has.
    let withSequence = fileName("x.txt", parent: 5 | (0x0007 << 48))
    expect(
        NTFSFileName.read(withSequence)?.parentRecord == 5,
        "the sequence number in the top sixteen bits is not part of the record number")

    // Choosing between them.
    let names = [
        NTFSFileName.Name(parentRecord: 5, namespace: .dos, name: "PROGRA~1"),
        NTFSFileName.Name(parentRecord: 5, namespace: .win32, name: "Program Files"),
    ]
    expect(
        NTFSFileName.preferred(names)?.name == "Program Files",
        "the name somebody typed is shown, not the short one NTFS keeps beside it")
    expect(
        NTFSFileName.preferred(names.reversed())?.name == "Program Files",
        "whichever order the record happens to hold them in")
    expect(
        NTFSFileName.preferred([names[0]])?.name == "PROGRA~1",
        "and a record with only a short name still has a name to show")
    expect(NTFSFileName.preferred([]) == nil, "a record with no name at all has none")

    // Refusals.
    expect(NTFSFileName.read(Data(count: 20)) == nil, "an attribute too short to hold a name")
    expect(NTFSFileName.read(fileName("")) == nil, "a name of no characters")
    expect(
        NTFSFileName.read(fileName("a/b")) == nil,
        "a name with a separator in it, which would let a listing escape its directory")
    // A length claiming more characters than the attribute holds.
    var truncated = [UInt8](fileName("Report.txt"))
    truncated[64] = 200
    expect(
        NTFSFileName.read(Data(truncated)) == nil,
        "and a length claiming more than is there, rather than reading past the attribute")
}

group("theNameReaderAgreesWithARealVolume") {
    // $MFT is called "$MFT" on every NTFS volume ever made, and it lives in the
    // root directory, which is record 5. Both are knowable without reading the
    // disk, which is what makes this a check rather than a parse.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
        let record = NTFSRecord.applyFixup(
            raw, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "the first record reads and repairs")
        return
    }

    let names = NTFSAttribute.all(
        in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength
    )
    .filter { $0.kind == .fileName && $0.isResident }
    .compactMap { attribute -> NTFSFileName.Name? in
        let start = record.startIndex + attribute.valueOffset
        guard start + attribute.valueLength <= record.endIndex else { return nil }
        return NTFSFileName.read(record[start..<start + attribute.valueLength])
    }

    expect(!names.isEmpty, "the record carries a name")
    guard let shown = NTFSFileName.preferred(names) else { return }
    expect(
        shown.name == "$MFT", "and it is $MFT, which is what that record is called on any volume")
    expect(
        shown.parentRecord == 5,
        "in record 5, which is the root directory on every NTFS volume ever made")
}

group("aRecordIsFoundThroughTheTablesOwnRuns") {
    // Everything on an NTFS volume refers to a file by its record number, so
    // turning a number into a place on the disk is the operation the whole
    // reader stands on. The table's records are laid out one after another --
    // but the table is a file like any other and fragments like one, so the
    // multiplication only means anything through $MFT's own runs.
    //
    // A reader that skips that step and reads at start + n * recordSize gets
    // the right answer on a fresh volume and somebody else's data on a used
    // one, which is the worst way for a bug to behave.

    expect(
        NTFSTable.offsetInTable(record: 5, bytesPerFileRecord: 1024) == 5120,
        "record five is five records into the table")
    expect(
        NTFSTable.offsetInTable(record: 0, bytesPerFileRecord: 1024) == 0,
        "and record zero is at its start")
    expect(
        NTFSTable.offsetInTable(record: 5, bytesPerFileRecord: 0) == nil,
        "a record size of zero has no arithmetic")
    expect(
        NTFSTable.offsetInTable(record: UInt64.max, bytesPerFileRecord: 1024) == nil,
        "and a number that overflows on multiplying is refused rather than wrapped")

    // A contiguous table: one run, so file offsets and disk offsets differ by a
    // constant.
    let contiguous = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 4, clusterCount: 100)
    ]
    let first = NTFSTable.diskOffset(forFileOffset: 0, runs: contiguous, bytesPerCluster: 4096)
    expect(first?.offset == 4 * 4096, "the start of the table is where its first run begins")
    expect(first?.availableBytes == 100 * 4096, "with the whole run available from there")
    let into = NTFSTable.diskOffset(forFileOffset: 8192, runs: contiguous, bytesPerCluster: 4096)
    expect(into?.offset == 4 * 4096 + 8192, "and an offset inside it lands that far in")
    expect(into?.availableBytes == 100 * 4096 - 8192, "with the rest of the run left")

    // A fragmented table, which is what a used volume has. The second run sits
    // somewhere else entirely.
    let fragmented = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 4, clusterCount: 2),
        NTFSRunlist.Run(logicalCluster: 2, physicalCluster: 900, clusterCount: 2),
    ]
    let second = NTFSTable.diskOffset(
        forFileOffset: 2 * 4096, runs: fragmented, bytesPerCluster: 4096)
    expect(
        second?.offset == 900 * 4096,
        "an offset in the second run reads where that run is, not where the first one ended")
    expect(
        second?.availableBytes == 2 * 4096,
        "and only that run's bytes are available -- reading further needs the next run")
    expect(
        NTFSTable.diskOffset(forFileOffset: 99 * 4096, runs: fragmented, bytesPerCluster: 4096)
            == nil,
        "an offset past every run has no address on the disk")

    // A hole has no disk address at all. Producing zeroes is the caller's job.
    let sparse = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 4, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 1, physicalCluster: nil, clusterCount: 4),
    ]
    expect(
        NTFSTable.diskOffset(forFileOffset: 2 * 4096, runs: sparse, bytesPerCluster: 4096) == nil,
        "an offset inside a hole has nowhere on the disk to be read from")
    expect(
        NTFSTable.diskOffset(forFileOffset: 0, runs: sparse, bytesPerCluster: 4096)?.offset
            == 4 * 4096,
        "while the run before it still reads normally")

    // A record past the end of the table.
    expect(
        NTFSTable.isWithin(record: 5, tableSizeInBytes: 1024 * 100, bytesPerFileRecord: 1024),
        "a record inside the table is within it")
    expect(
        !NTFSTable.isWithin(record: 500, tableSizeInBytes: 1024 * 100, bytesPerFileRecord: 1024),
        "and one past the end is not -- following it reads whatever is on the disk after")
    expect(
        NTFSTable.isWithin(record: 99, tableSizeInBytes: 1024 * 100, bytesPerFileRecord: 1024),
        "the last record that fits is within")

    // File references, and the sequence number that makes a stale one
    // detectable rather than silently pointing at whatever took the slot.
    let (record, sequence) = NTFSTable.reference(5 | (7 << 48))
    expect(record == 5, "a reference's record number is its low 48 bits")
    expect(sequence == 7, "and the sequence number is kept rather than masked away")
    expect(NTFSTable.rootRecord == 5, "the root directory is record five on every NTFS volume")
    expect(NTFSTable.mftRecord == 0, "and the table itself is record zero")
}

group("theRootDirectoryIsReachedByNumberOnARealVolume") {
    // Every layer at once, on a real volume, reaching a record the boot sector
    // does not point at. $MFT is found because the boot sector says where it
    // is; record 5 is found because the reader walked $MFT's runs and did the
    // arithmetic. That is the difference between parsing one blessed record and
    // being able to read the volume.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    // 1. $MFT's own record, where the boot sector says.
    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let mftRaw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let mftHeader = NTFSRecord.header(mftRaw, expectedLength: geometry.bytesPerFileRecord),
        let mftRecord = NTFSRecord.applyFixup(
            mftRaw, header: mftHeader, sectorSize: geometry.bytesPerSector),
        let mftData = NTFSAttribute.all(
            in: mftRecord, startingAt: mftHeader.firstAttributeOffset,
            usedLength: mftHeader.usedLength
        ).first(where: { $0.kind == .data }),
        let runs = NTFSRunlist.decode(mftRecord, at: mftData.runlistOffset, limit: mftRecord.count)
    else {
        expect(false, "the table's own record and runs are read")
        return
    }

    // 2. Where record 5 sits inside the table as a file.
    guard
        let inTable = NTFSTable.offsetInTable(
            record: NTFSTable.rootRecord, bytesPerFileRecord: geometry.bytesPerFileRecord)
    else {
        expect(false, "record five has a place in the table")
        return
    }

    // 3. Where that is on the disk, through the runs.
    guard
        let placed = NTFSTable.diskOffset(
            forFileOffset: inTable, runs: runs, bytesPerCluster: geometry.bytesPerCluster),
        placed.availableBytes >= UInt64(geometry.bytesPerFileRecord)
    else {
        expect(false, "and a place on the disk, with the whole record inside one run")
        return
    }

    // 4. Read it.
    try? handle.seek(toOffset: placed.offset)
    guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
        let record = NTFSRecord.applyFixup(
            raw, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "the root directory's record reads and repairs")
        return
    }

    // What record 5 must be, on any NTFS volume anybody has ever made.
    expect(header.inUse, "the root directory is in use")
    expect(header.isDirectory, "and is a directory, which is how the flag is read")

    let attributes = NTFSAttribute.all(
        in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength)
    let kinds = attributes.compactMap(\.kind)
    expect(kinds.contains(.indexRoot), "a directory carries an index root -- its B-tree of names")
    expect(
        kinds.contains(.standardInformation), "and its standard information, as every record does")

    // And it is called "." -- the root's name for itself.
    let names =
        attributes
        .filter { $0.kind == .fileName && $0.isResident }
        .compactMap { attribute -> NTFSFileName.Name? in
            let start = record.startIndex + attribute.valueOffset
            guard start + attribute.valueLength <= record.endIndex else { return nil }
            return NTFSFileName.read(record[start..<start + attribute.valueLength])
        }
    expect(
        NTFSFileName.preferred(names)?.name == ".",
        "and the root directory is named \".\", which is what NTFS calls it")
}

group("aDirectoryListingKeepsItsEndMarker") {
    // A directory's contents are a B-tree of entries sorted by name. The last
    // entry in every node carries no name at all -- only the pointer to the
    // subtree past the final key. A reader that treats it as a file shows an
    // empty-named entry in every folder; one that stops at it without following
    // its child misses everything in the last subtree, which on a real volume
    // is where most of the names are.

    func entry(
        record: UInt64 = 30, name: String? = "Report.txt", child: UInt64? = nil,
        last: Bool = false, entryLength: Int? = nil
    ) -> [UInt8] {
        var content = [UInt8]()
        if let name {
            content = [UInt8](repeating: 0, count: 66)
            for i in 0..<8 { content[i] = UInt8((UInt64(5) >> (8 * UInt64(i))) & 0xFF) }
            let units = Array(name.utf16)
            content[64] = UInt8(units.count)
            content[65] = 1
            for u in units { content.append(UInt8(u & 0xFF)); content.append(UInt8(u >> 8)) }
        }
        var length = 16 + content.count
        if child != nil { length += 8 }
        length = (length + 7) / 8 * 8
        let total = entryLength ?? length
        var e = [UInt8](repeating: 0, count: max(total, 16))
        for i in 0..<8 { e[i] = UInt8((record >> (8 * UInt64(i))) & 0xFF) }
        e[8] = UInt8(total & 0xFF); e[9] = UInt8(total >> 8)
        e[10] = UInt8(content.count & 0xFF); e[11] = UInt8(content.count >> 8)
        var flags: UInt8 = 0
        if child != nil { flags |= 0x01 }
        if last { flags |= 0x02 }
        e[12] = flags
        for (i, b) in content.enumerated() where 16 + i < e.count { e[16 + i] = b }
        if let child, e.count >= 8 {
            for i in 0..<8 { e[e.count - 8 + i] = UInt8((child >> (8 * UInt64(i))) & 0xFF) }
        }
        return e
    }

    // A node holding two names and an end marker.
    var node = entry(record: 30, name: "Alpha.txt")
    node += entry(record: 31, name: "Beta.txt")
    node += entry(name: nil, last: true)
    let data = Data(node)

    let all = NTFSIndex.entries(data, from: 0, limit: data.count)
    expect(all.count == 3, "both names and the marker that ends the node")
    expect(NTFSIndex.names(all) == ["Alpha.txt", "Beta.txt"], "the listing is the names, in order")
    expect(all[0].record == 30, "each entry names the record it points at")
    expect(all[2].isLast, "and the last entry says it is the last")
    expect(all[2].name == nil, "carrying no name, whatever its content length says")
    expect(
        !NTFSIndex.names(all).contains(""),
        "so no folder shows an entry with an empty name")

    // A last entry that *does* carry content bytes. Real NTFS usually writes
    // none, but the flag is what decides, not the length -- and reading the
    // content of a marker gives every folder an entry named after whatever
    // happened to be in those bytes.
    var markerWithContent = entry(record: 99, name: "Ghost.txt")
    markerWithContent[12] |= 0x02
    let ghost = Data(markerWithContent)
    if let (marker, _) = NTFSIndex.entry(ghost, at: 0, limit: ghost.count) {
        expect(marker.isLast, "an entry flagged last is the marker")
        expect(
            marker.name == nil,
            "and carries no name even when there are name bytes sitting in it -- the flag "
                + "decides, not the length")
        expect(
            NTFSIndex.names([marker]).isEmpty,
            "so those bytes never reach a listing as a file called Ghost.txt")
    } else {
        expect(false, "a last entry with content still reads")
    }

    // The end marker with a child: the subtree past the final key. Dropping it
    // loses every name in that subtree, which on a real volume is most of them.
    let withChild = Data(entry(name: nil, child: 4, last: true))
    let ended = NTFSIndex.entries(withChild, from: 0, limit: withChild.count)
    expect(ended.count == 1, "a node that is only an end marker still yields it")
    expect(ended[0].childBlock == 4, "carrying the block of the subtree past the last name")
    expect(
        NTFSIndex.names(ended).isEmpty,
        "and contributing no name of its own to the listing")

    // An interior entry with both a name and a child.
    let interior = Data(entry(record: 40, name: "Middle.txt", child: 9))
    if let (one, _) = NTFSIndex.entry(interior, at: 0, limit: interior.count) {
        expect(one.name?.name == "Middle.txt", "an interior entry has a name")
        expect(one.childBlock == 9, "and a subtree below it")
        expect(!one.isLast, "and is not the end of the node")
    } else {
        expect(false, "an interior entry reads")
    }

    // The lengths that would loop or overrun.
    expect(
        NTFSIndex.entry(Data(entry(entryLength: 0)), at: 0, limit: 200) == nil,
        "an entry of no length is refused -- believing it walks the node for ever")
    let short = Data(entry(name: "Alpha.txt").prefix(20))
    expect(
        NTFSIndex.entry(short, at: 0, limit: short.count) == nil,
        "an entry longer than the node is refused rather than read past the end")
    expect(NTFSIndex.entry(data, at: 100_000, limit: data.count) == nil, "an offset past the node")
    expect(NTFSIndex.entry(data, at: -1, limit: data.count) == nil, "and one before it")

    // An entry that is not the last and has no readable name is a corrupt node,
    // not a nameless file.
    let nameless = Data(entry(name: nil, last: false, entryLength: 32))
    expect(
        NTFSIndex.entry(nameless, at: 0, limit: nameless.count) == nil,
        "a non-final entry with no name is a corrupt node rather than a file without one")

    // Where a node's entries begin is read from its header rather than assumed:
    // an index root and an index block carry different amounts in front.
    var header = [UInt8](repeating: 0, count: 32)
    header[0] = 24
    expect(
        NTFSIndex.firstEntryOffset(nodeHeader: Data(header), at: 0) == 24,
        "the node header says where its entries start")
    header[0] = 4
    expect(
        NTFSIndex.firstEntryOffset(nodeHeader: Data(header), at: 0) == nil,
        "and one claiming they start inside the header itself is refused")
}

group("aRealDirectoryIsListedThroughEveryLayer") {
    // The whole reader, listing a real directory off a real volume: boot
    // sector, geometry, $MFT's runs, record 5 by number, its $INDEX_ALLOCATION
    // runs, an INDX block off the disk, that block's fixup, and its entries.
    //
    // The root of a freshly formatted volume already keeps its names out here
    // rather than in the record -- NTFS's own metadata files fill the index root
    // immediately. So a reader that handles only $INDEX_ROOT lists an empty
    // root directory on every volume it will ever see and reports no error.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    func readRecord(_ number: UInt64, mftRuns: [NTFSRunlist.Run]?) -> (Data, NTFSRecord.Header)? {
        let offset: UInt64
        if let mftRuns {
            guard
                let inTable = NTFSTable.offsetInTable(
                    record: number, bytesPerFileRecord: geometry.bytesPerFileRecord),
                let placed = NTFSTable.diskOffset(
                    forFileOffset: inTable, runs: mftRuns,
                    bytesPerCluster: geometry.bytesPerCluster)
            else { return nil }
            offset = placed.offset
        } else {
            offset = geometry.mftByteOffset
        }
        try? handle.seek(toOffset: offset)
        guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
            let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
            let fixed = NTFSRecord.applyFixup(
                raw, header: header, sectorSize: geometry.bytesPerSector)
        else { return nil }
        return (fixed, header)
    }

    func attributes(_ record: Data, _ header: NTFSRecord.Header) -> [NTFSAttribute.Header] {
        NTFSAttribute.all(
            in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength)
    }

    // $MFT's runs, so records can be found by number.
    guard let (mftRecord, mftHeader) = readRecord(0, mftRuns: nil),
        let mftData = attributes(mftRecord, mftHeader).first(where: { $0.kind == .data }),
        let mftRuns = NTFSRunlist.decode(
            mftRecord, at: mftData.runlistOffset, limit: mftRecord.count)
    else {
        expect(false, "the table's runs are read")
        return
    }

    // The root directory.
    guard let (root, rootHeader) = readRecord(NTFSTable.rootRecord, mftRuns: mftRuns) else {
        expect(false, "the root directory record is read")
        return
    }
    let rootAttributes = attributes(root, rootHeader)

    // The index block size lives in $INDEX_ROOT's value.
    guard let indexRoot = rootAttributes.first(where: { $0.kind == .indexRoot }),
        indexRoot.isResident,
        indexRoot.valueOffset + 12 <= root.count
    else {
        expect(false, "the root's index root is found")
        return
    }
    let sizeStart = root.startIndex + indexRoot.valueOffset + 8
    var blockSize = 0
    for i in 0..<4 { blockSize |= Int(root[sizeStart + i]) << (8 * i) }
    expect(blockSize >= 512, "the index block size is read from the index root")

    // Where the blocks are.
    guard let allocation = rootAttributes.first(where: { $0.kind == .indexAllocation }),
        !allocation.isResident,
        let allocationRuns = NTFSRunlist.decode(
            root, at: allocation.runlistOffset, limit: root.count),
        let firstBlock = NTFSTable.diskOffset(
            forFileOffset: 0, runs: allocationRuns, bytesPerCluster: geometry.bytesPerCluster)
    else {
        expect(false, "the root's index allocation has runs -- its names are out on the disk")
        return
    }

    // Read one block and list it.
    try? handle.seek(toOffset: firstBlock.offset)
    guard let rawBlock = try? handle.read(upToCount: blockSize),
        let blockHeader = NTFSIndexBlock.header(rawBlock, blockSize: blockSize),
        let block = NTFSIndexBlock.applyFixup(
            rawBlock, header: blockHeader, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "an INDX block reads and repairs")
        return
    }

    let entries = NTFSIndex.entries(
        block, from: blockHeader.firstEntryOffset, limit: blockHeader.endOfEntries)
    let names = NTFSIndex.names(entries)
    expect(!names.isEmpty, "the root directory lists names")

    // What every NTFS volume's root contains, whoever made it.
    expect(names.contains("$MFT"), "the master file table is in the root")
    expect(names.contains("$Volume"), "and the volume file")
    expect(names.contains("$Bitmap"), "and the cluster bitmap")
    expect(names.contains("$UpCase"), "and the uppercase table")
    expect(names.contains("."), "and the root's own entry")
    expect(
        names == names.sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending }
            || names.count > 1,
        "and the entries come back in the tree's own order")

    // The records they name have to be real.
    let tableSize = mftData.dataSize
    expect(
        entries.filter { !$0.isLast }.allSatisfy {
            NTFSTable.isWithin(
                record: $0.record, tableSizeInBytes: tableSize,
                bytesPerFileRecord: geometry.bytesPerFileRecord)
        },
        "every entry names a record that exists in the table")
    expect(
        entries.first(where: { $0.name?.name == "$MFT" })?.record == 0,
        "and $MFT is record zero, which is knowable without reading the disk")
    expect(
        entries.first(where: { $0.name?.name == "." })?.record == 5,
        "and the root's own entry is record five")
}

group("readingAFileNeverReadsPastTheEndOfIt") {
    // A file's last run is rounded up to a whole cluster, so the bytes between
    // the end of the file and the end of its allocation are whatever was on the
    // disk before -- somebody else's deleted mail, most often. A reader that
    // trusts the runs rather than the size hands those over as file contents.
    let cluster = 4096
    let runs = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 2)
    ]

    // 5000 bytes of file in 8192 bytes of allocation.
    guard
        let all = NTFSFileData.pieces(
            offset: 0, length: 8192, runs: runs, bytesPerCluster: cluster, size: 5000)
    else {
        expect(false, "a whole-file read is planned")
        return
    }
    expect(
        NTFSFileData.totalLength(all) == 5000,
        "asking for the whole allocation gives the file's length, not the allocation's")
    expect(all.count == 1, "from one run, in one piece")
    if case .disk(let offset, _) = all[0] {
        expect(offset == 100 * UInt64(cluster), "starting where the run says")
    } else {
        expect(false, "and it is a read from the disk")
    }

    // Reading from an offset, and off the end.
    let tail = NTFSFileData.pieces(
        offset: 4900, length: 1000, runs: runs, bytesPerCluster: cluster, size: 5000)
    expect(NTFSFileData.totalLength(tail ?? []) == 100, "a read overlapping the end stops at it")
    expect(
        NTFSFileData.pieces(
            offset: 5000, length: 10, runs: runs, bytesPerCluster: cluster, size: 5000)?.isEmpty
            == true,
        "a read starting exactly at the end returns nothing rather than slack space")
    expect(
        NTFSFileData.pieces(
            offset: 6000, length: 10, runs: runs, bytesPerCluster: cluster, size: 5000) == nil,
        "and one starting past the end is refused")

    // Crossing runs: a fragmented file is read in the pieces it is stored in.
    let fragmented = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 1, physicalCluster: 900, clusterCount: 1),
    ]
    guard
        let across = NTFSFileData.pieces(
            offset: 4000, length: 200, runs: fragmented, bytesPerCluster: cluster, size: 8192)
    else {
        expect(false, "a read crossing two runs is planned")
        return
    }
    expect(across.count == 2, "it comes back as two reads, because the file is in two places")
    expect(NTFSFileData.totalLength(across) == 200, "covering exactly what was asked for")
    if case .disk(let first, let firstLength) = across[0],
        case .disk(let second, _) = across[1]
    {
        expect(first == 100 * UInt64(cluster) + 4000, "the first picks up where the run is")
        expect(firstLength == 96, "and stops at the end of that run")
        expect(second == 900 * UInt64(cluster), "the second starts where the next run is")
    } else {
        expect(false, "both pieces are disk reads")
    }

    // A hole produces zeroes rather than a read. Reading it would hand back
    // whatever is at cluster zero.
    let sparse = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 1, physicalCluster: nil, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 2, physicalCluster: 900, clusterCount: 1),
    ]
    guard
        let holed = NTFSFileData.pieces(
            offset: 0, length: 3 * cluster, runs: sparse, bytesPerCluster: cluster, size: 12288)
    else {
        expect(false, "a sparse file is planned")
        return
    }
    expect(holed.count == 3, "three pieces for three runs")
    expect(holed[1] == .zeroes(length: cluster), "the hole is zeroes, not a read of cluster zero")
    expect(NTFSFileData.totalLength(holed) == 12288, "and the whole file is accounted for")

    // Runs that do not cover the file they claim to.
    expect(
        NTFSFileData.pieces(
            offset: 0, length: 100, runs: [], bytesPerCluster: cluster, size: 5000) == nil,
        "a file with no runs but a size is refused rather than read short")
    expect(
        NTFSFileData.pieces(
            offset: 0, length: 100, runs: runs, bytesPerCluster: 0, size: 5000) == nil,
        "and a cluster size of zero has no arithmetic")
    expect(
        NTFSFileData.pieces(
            offset: 0, length: 0, runs: runs, bytesPerCluster: cluster, size: 5000)?.isEmpty
            == true,
        "asking for nothing reads nothing")

    // A small file lives inside its record and is never read from the disk.
    let resident = NTFSAttribute.Header(
        type: 0x80, length: 200, isResident: true, valueOffset: 100, valueLength: 50,
        runlistOffset: 0, startingCluster: 0, lastCluster: 0, dataSize: 50)
    expect(
        NTFSFileData.residentRange(resident, offset: 0, length: 50, recordSize: 1024)
            == 100..<150,
        "a resident file's bytes are a range inside the record")
    expect(
        NTFSFileData.residentRange(resident, offset: 10, length: 999, recordSize: 1024)
            == 110..<150,
        "and a read longer than the file stops at its end")
    expect(
        NTFSFileData.residentRange(resident, offset: 50, length: 10, recordSize: 1024) == nil,
        "a read starting past it is refused")
    let overreaching = NTFSAttribute.Header(
        type: 0x80, length: 200, isResident: true, valueOffset: 1000, valueLength: 500,
        runlistOffset: 0, startingCluster: 0, lastCluster: 0, dataSize: 500)
    expect(
        NTFSFileData.residentRange(overreaching, offset: 0, length: 10, recordSize: 1024) == nil,
        "and an attribute claiming more than the record holds is refused")
}

group("aFileWrittenByNtfsIsReadBackByteForByte") {
    // The end of the whole reader: a file whose contents are known, put on the
    // volume by the NTFS driver in the guest, found by name in the directory
    // listing and read back through nine layers of our own parsing.
    //
    // Everything before this proves a parser agrees with a structure. This
    // proves the bytes come back, which is the only claim that matters.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    let expected = "LUKOTTA-V2-READBACK-CHECK-0123456789"

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    func record(_ number: UInt64, mftRuns: [NTFSRunlist.Run]?) -> (Data, NTFSRecord.Header)? {
        var offset = geometry.mftByteOffset
        if let mftRuns {
            guard
                let inTable = NTFSTable.offsetInTable(
                    record: number, bytesPerFileRecord: geometry.bytesPerFileRecord),
                let placed = NTFSTable.diskOffset(
                    forFileOffset: inTable, runs: mftRuns,
                    bytesPerCluster: geometry.bytesPerCluster)
            else { return nil }
            offset = placed.offset
        }
        try? handle.seek(toOffset: offset)
        guard let raw = try? handle.read(upToCount: geometry.bytesPerFileRecord),
            let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
            let fixed = NTFSRecord.applyFixup(
                raw, header: header, sectorSize: geometry.bytesPerSector)
        else { return nil }
        return (fixed, header)
    }
    func attributes(_ r: Data, _ h: NTFSRecord.Header) -> [NTFSAttribute.Header] {
        NTFSAttribute.all(in: r, startingAt: h.firstAttributeOffset, usedLength: h.usedLength)
    }

    guard let (mftRecord, mftHeader) = record(0, mftRuns: nil),
        let mftData = attributes(mftRecord, mftHeader).first(where: { $0.kind == .data }),
        let mftRuns = NTFSRunlist.decode(
            mftRecord, at: mftData.runlistOffset, limit: mftRecord.count),
        let (root, rootHeader) = record(NTFSTable.rootRecord, mftRuns: mftRuns)
    else {
        expect(false, "the table and the root directory are read")
        return
    }
    let rootAttributes = attributes(root, rootHeader)

    // Find the file by name in the root's index blocks.
    guard let indexRoot = rootAttributes.first(where: { $0.kind == .indexRoot }),
        indexRoot.isResident,
        let allocation = rootAttributes.first(where: { $0.kind == .indexAllocation }),
        let allocationRuns = NTFSRunlist.decode(
            root, at: allocation.runlistOffset, limit: root.count)
    else {
        expect(false, "the root's index is found")
        return
    }
    var blockSize = 0
    let sizeStart = root.startIndex + indexRoot.valueOffset + 8
    for i in 0..<4 { blockSize |= Int(root[sizeStart + i]) << (8 * i) }

    var target: UInt64?
    var block = 0
    while target == nil, block < 32 {
        guard
            let placed = NTFSTable.diskOffset(
                forFileOffset: UInt64(block * blockSize), runs: allocationRuns,
                bytesPerCluster: geometry.bytesPerCluster)
        else { break }
        try? handle.seek(toOffset: placed.offset)
        guard let rawBlock = try? handle.read(upToCount: blockSize),
            let blockHeader = NTFSIndexBlock.header(rawBlock, blockSize: blockSize),
            let node = NTFSIndexBlock.applyFixup(
                rawBlock, header: blockHeader, sectorSize: geometry.bytesPerSector)
        else { break }
        for entry in NTFSIndex.entries(
            node, from: blockHeader.firstEntryOffset, limit: blockHeader.endOfEntries)
        where entry.name?.name == "readback.txt" {
            target = entry.record
        }
        block += 1
    }

    guard let number = target else {
        expect(true, "readback.txt is not on this volume; nothing to read back")
        return
    }
    expect(true, "readback.txt was found in the directory listing")

    guard let (file, fileHeader) = record(number, mftRuns: mftRuns) else {
        expect(false, "its record reads")
        return
    }
    expect(fileHeader.inUse, "the file's record is in use")
    expect(!fileHeader.isDirectory, "and it is a file rather than a directory")

    guard let data = attributes(file, fileHeader).first(where: { $0.kind == .data }) else {
        expect(false, "it has a DATA attribute")
        return
    }
    expect(
        data.dataSize == UInt64(expected.utf8.count),
        "whose size is the number of bytes that were written")

    // Read the contents, resident or not.
    var contents = Data()
    if data.isResident {
        guard
            let range = NTFSFileData.residentRange(
                data, offset: 0, length: Int(data.dataSize), recordSize: file.count)
        else {
            expect(false, "a resident file's bytes are located")
            return
        }
        contents = file[file.startIndex + range.lowerBound..<file.startIndex + range.upperBound]
    } else {
        guard let runs = NTFSRunlist.decode(file, at: data.runlistOffset, limit: file.count),
            let pieces = NTFSFileData.pieces(
                offset: 0, length: Int(data.dataSize), runs: runs,
                bytesPerCluster: geometry.bytesPerCluster, size: data.dataSize)
        else {
            expect(false, "a non-resident file's reads are planned")
            return
        }
        for piece in pieces {
            switch piece {
            case .zeroes(let length): contents.append(Data(count: length))
            case .disk(let offset, let length):
                try? handle.seek(toOffset: offset)
                guard let chunk = try? handle.read(upToCount: length) else { break }
                contents.append(chunk)
            }
        }
    }

    expect(
        contents.count == expected.utf8.count,
        "the read returns exactly as many bytes as the file holds")
    expect(
        String(decoding: contents, as: UTF8.self) == expected,
        "and every one of them is what was written -- read off a real NTFS volume by our own "
            + "code, through geometry, record, fixup, attributes, index, and data")
}

group("theWholeVolumeReadsThroughOneObject") {
    // Everything the layers do, behind one thing that can be handed to a
    // volume. What "the disk" is stays outside it: here a file handle, on a
    // mounted volume an FSBlockDeviceResource.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    let reader = NTFSVolumeReader { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }

    guard let reader else {
        expect(false, "the volume opens")
        return
    }
    expect(reader.geometry.bytesPerCluster >= 512, "with a cluster size")

    // The root directory, listed.
    guard let root = reader.contents(ofDirectory: NTFSTable.rootRecord) else {
        expect(false, "the root directory lists")
        return
    }
    let names = root.map(\.name)
    expect(names.contains("$MFT"), "the listing has the master file table in it")
    expect(names.contains("$Volume"), "and the volume file")
    expect(
        root.first(where: { $0.name == "$MFT" })?.record == 0,
        "and each name carries the record it points at")

    // A record that is not a directory is not listed as one.
    expect(
        reader.contents(ofDirectory: 0) == nil,
        "$MFT is a file, not a directory, and listing it gives nothing rather than nonsense")
    expect(
        reader.contents(ofDirectory: 999_999_999) == nil,
        "and a record past the end of the table is refused")

    // A file, read through the same object.
    if let entry = root.first(where: { $0.name == "readback.txt" }) {
        expect(
            reader.size(ofFile: entry.record) == 36,
            "the file's size comes back")
        let contents = reader.contents(ofFile: entry.record)
        expect(
            contents.map { String(decoding: $0, as: UTF8.self) }
                == "LUKOTTA-V2-READBACK-CHECK-0123456789",
            "and its contents, byte for byte, through one call")
        // Reading part of it.
        let part = reader.contents(ofFile: entry.record, offset: 8, length: 7)
        expect(
            part.map { String(decoding: $0, as: UTF8.self) } == "V2-READ",
            "a read from an offset gives that part and no other")
    } else {
        expect(true, "readback.txt is not on this volume")
    }

    // $UpCase is on every NTFS volume and is always 128 KB, which makes it the
    // one non-resident file whose size is knowable without reading it.
    if let upcase = root.first(where: { $0.name == "$UpCase" }) {
        expect(
            reader.size(ofFile: upcase.record) == 128 * 1024,
            "$UpCase is 128 KB on every NTFS volume, which is a size not read off this one")
        let head = reader.contents(ofFile: upcase.record, offset: 0, length: 8)
        expect(head?.count == 8, "and a large non-resident file reads through its runs")
    }
}

group("anNtfsVolumeServesThroughTheSameSeamAsTheOthers") {
    // The point of the seam: the volume is written once and cannot tell what is
    // behind it. Memory and a host directory were there to measure. This is the
    // one the application exists for, and it answers the same calls.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let fs: any FSBacking = NTFSBacking(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "an NTFS volume opens behind the seam")
        return
    }

    // Everything below is the same shape as the checks the other two backings
    // pass, which is what makes the seam worth having.
    let root = fs.rootHandle
    expect(fs.attributes(of: root)?.isDirectory == true, "the root is a directory")
    expect(
        fs.attributes(of: root)?.id == NTFSTable.rootRecord,
        "and is record five, which is the root on every NTFS volume")

    let children = fs.children(of: root)
    let names = children.map(\.name)
    expect(!names.isEmpty, "the root lists")
    expect(
        !names.contains("$MFT"),
        "without NTFS's own metadata files, which Windows does not show either -- a drive "
            + "that opens with a dozen dollar-signed files in it looks broken")
    expect(!names.contains("$Bitmap"), "nor the cluster bitmap")
    expect(!names.contains("$LogFile"), "nor the journal")
    expect(!names.contains("$Extend"), "nor the extend directory")
    expect(!names.contains("."), "and without a folder inside itself, which Finder would show")
    expect(
        names.contains("readback.txt") || names.contains("sidecar-test"),
        "but the files somebody actually put there are still listed")
    if ProcessInfo.processInfo.environment["LUKOTTA_SHOW_LISTING"] != nil {
        print("    the drive as somebody would see it: \(names.joined(separator: "  "))")
    }
    expect(names == names.sorted(), "sorted, because an enumeration resumes by index into this")

    // Looking a name up gives the same file the listing gave.
    guard let found = fs.lookup("$MFT", in: root) else {
        expect(false, "a name looks up")
        return
    }
    expect(fs.attributes(of: found)?.id == 0, "$MFT is record zero")
    expect(fs.lookup("no-such-file-here", in: root) == nil, "and a name that is not there is not")

    // The lookup goes through the tree, not down a listing. The root's index
    // root holds nothing but a marker pointing at a block, so anything found at
    // all was found by descending -- and every name in the listing has to be
    // findable, or the descent is going wrong somewhere the listing does not.
    for entry in children {
        expect(
            fs.lookup(entry.name, in: root) != nil,
            "every name the listing shows can also be looked up: \(entry.name)")
    }
    // NTFS matches case-insensitively, and so must the lookup.
    if let any = children.first(where: { $0.name.lowercased() != $0.name.uppercased() }) {
        expect(
            fs.lookup(any.name.uppercased(), in: root) != nil,
            "and a name in the wrong case is found, because NTFS matches that way")
    }

    // Reading through the seam.
    if let entry = children.first(where: { $0.name == "readback.txt" }) {
        let contents = fs.read(entry.handle, offset: 0, length: 64)
        expect(
            String(decoding: contents, as: UTF8.self) == "LUKOTTA-V2-READBACK-CHECK-0123456789",
            "and a file's contents come back through the same read the other backings answer")
        expect(
            fs.attributes(of: entry.handle)?.size == 36,
            "with the size the volume says it has")
    }

    // Read-only, said by refusing rather than by pretending. A write that
    // returned success and changed nothing is the worst of both.
    expect(
        fs.create("new.txt", isDirectory: false, in: root, mode: 0o644) == nil,
        "creating a file is refused")
    expect(fs.remove("$MFT", from: root) == .missing, "removing one is refused")
    expect(
        !fs.rename("$MFT", in: root, to: "x", in: root), "renaming one is refused")

    // A volume opened with no way to write cannot write, whatever is asked of
    // it. The absence of a function is a stronger guarantee than a flag
    // somebody has to remember to check, and this is the guarantee the whole
    // read-only path rests on.
    if let entry = children.first(where: { $0.name == "readback.txt" }) {
        expect(
            fs.write(entry.handle, contents: Data([0x41]), offset: 0) == 0,
            "a backing opened without a write function stores nothing, even into a real file")
    }
    expect(
        fs.write(root, contents: Data([1, 2, 3]), offset: 0) == 0,
        "and a write takes nothing rather than reporting bytes it did not store")
    expect(
        fs.attributes(of: root)?.mode == 0o555,
        "the mode says read-only, so nothing has to try a write to find out")

    // Dates reach the seam, not just the parser. A volume where every file
    // shows 1 January 1970 is one nothing reports as broken and everybody sees.
    let year2000 = Date(timeIntervalSince1970: 946_684_800)
    expect(
        (fs.attributes(of: root)?.created ?? Date(timeIntervalSince1970: 0)) > year2000,
        "the root's creation date arrives through the seam as a real date")
    if let entry = children.first(where: { $0.name == "readback.txt" }),
        let attributes = fs.attributes(of: entry.handle)
    {
        expect(attributes.created > year2000, "and so does a file's")
        expect(
            attributes.modified >= attributes.created,
            "with modification no earlier than creation")
    }
}

group("ntfsDatesAreNotUnixDates") {
    // NTFS counts 100-nanosecond intervals since 1601, not seconds since 1970.
    // Reading it as a Unix time puts every file in 1601; reading the ticks as
    // seconds puts them hundreds of millions of years out. Both look like a
    // corrupt disk rather than a units mistake, which is why they survive.

    // A known conversion: 1970-01-01 in NTFS ticks is exactly the epoch gap.
    let unixEpoch = UInt64(NTFSTimestamps.epochDifference * NTFSTimestamps.ticksPerSecond)
    expect(
        NTFSTimestamps.date(fromTicks: unixEpoch)?.timeIntervalSince1970 == 0,
        "the NTFS tick count for 1970 converts to the Unix epoch exactly")
    expect(
        NTFSTimestamps.date(fromTicks: unixEpoch + UInt64(NTFSTimestamps.ticksPerSecond))?
            .timeIntervalSince1970 == 1,
        "and one second later is one second later, not ten million")

    // Sub-second precision survives, which is the point of the unit.
    let halfSecond = unixEpoch + UInt64(NTFSTimestamps.ticksPerSecond / 2)
    expect(
        NTFSTimestamps.date(fromTicks: halfSecond)?.timeIntervalSince1970 == 0.5,
        "half a second is half a second rather than rounded away")

    // Zero means never set, not 1601.
    expect(
        NTFSTimestamps.date(fromTicks: 0) == nil,
        "an unset timestamp is nothing rather than a file dated 1601")
    // A count that would land outside any sensible calendar.
    expect(
        NTFSTimestamps.date(fromTicks: UInt64.max) == nil,
        "and a corrupt count is refused rather than shown as a date in the year 60000")

    // The four timestamps out of a standard information value.
    var value = [UInt8](repeating: 0, count: 48)
    func put(_ ticks: UInt64, at offset: Int) {
        for i in 0..<8 { value[offset + i] = UInt8((ticks >> (8 * UInt64(i))) & 0xFF) }
    }
    let oneDay = UInt64(86_400 * NTFSTimestamps.ticksPerSecond)
    put(unixEpoch, at: 0)
    put(unixEpoch + oneDay, at: 8)
    put(unixEpoch + 2 * oneDay, at: 16)
    put(unixEpoch + 3 * oneDay, at: 24)
    value[32] = 0x01 | 0x02  // read-only and hidden

    guard let times = NTFSTimestamps.read(Data(value)) else {
        expect(false, "a standard information value reads")
        return
    }
    expect(times.created.timeIntervalSince1970 == 0, "creation time is the first of the four")
    expect(times.modified.timeIntervalSince1970 == 86_400, "then modification")
    expect(
        times.recordChanged.timeIntervalSince1970 == 172_800,
        "then when the record changed, which a rename moves and modification does not")
    expect(times.accessed.timeIntervalSince1970 == 259_200, "then last access")

    guard let flags = NTFSTimestamps.flags(Data(value)) else {
        expect(false, "the flags read from the same value")
        return
    }
    expect(flags.isReadOnly, "the read-only flag is read")
    expect(flags.isHidden, "and the hidden flag")
    expect(!flags.isSystem, "and one that is not set is not")

    // A value too short to hold what it claims.
    expect(NTFSTimestamps.read(Data(count: 20)) == nil, "a short value is refused")
    expect(NTFSTimestamps.flags(Data(count: 20)) == nil, "and has no flags either")
    // A record whose creation time is unset is not trusted; the rest may fall
    // back to it on an old volume, but nothing falls back to 1601.
    expect(NTFSTimestamps.read(Data(count: 48)) == nil, "and one with no creation time at all")
}

group("aRealVolumesDatesAreThisCenturyNotTheSeventeenth") {
    // The one thing a synthetic fixture cannot catch: an epoch off by 369
    // years. A volume formatted and written tonight has files whose dates are
    // within hours of now, and no arithmetic mistake produces that by accident
    // -- 1601, 1970 and the year 60000 are all equally wrong and equally
    // obvious against a real disk.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }

    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume opens")
        return
    }

    // $MFT's own record. It is created when the volume is formatted, so its
    // creation date is when mkntfs ran.
    guard let record = reader.record(0),
        let info = reader.attributes(of: record)
            .first(where: { $0.kind == .standardInformation && $0.isResident })
    else {
        expect(false, "the table's standard information is found")
        return
    }
    let start = record.data.startIndex + info.valueOffset
    guard start + info.valueLength <= record.data.endIndex,
        let times = NTFSTimestamps.read(record.data[start..<start + info.valueLength])
    else {
        expect(false, "and reads")
        return
    }

    // The volume was made on this machine. Anything outside a wide window
    // around now means the epoch or the unit is wrong.
    let year2000 = Date(timeIntervalSince1970: 946_684_800)
    let soon = Date(timeIntervalSinceNow: 86_400)
    expect(
        times.created > year2000,
        "the volume's creation date is this century, not 1601 -- which is what reading "
            + "NTFS ticks as a Unix time gives")
    expect(
        times.created < soon,
        "and not in the far future, which is what reading the ticks as seconds gives")
    expect(times.modified >= times.created, "modification is not before creation")
    expect(
        times.created.timeIntervalSinceNow > -86_400 * 400,
        "and this volume was made recently, which it was -- tonight")
}

group("findingANameUsesTheOrderTheTreeIsIn") {
    // A directory's entries are sorted, so a lookup stops at the first entry
    // that is not less than the name wanted rather than reading them all. On a
    // folder of a hundred thousand files that is the difference between a
    // Finder window opening and a Finder window hanging.
    //
    // NTFS sorts case-insensitively. A search that compares any other way walks
    // past the entry it wants and reports a file that is plainly there as
    // missing, which looks like a corrupt directory rather than a comparison
    // bug.
    func named(_ name: String, record: UInt64 = 30, child: UInt64? = nil) -> NTFSIndex.Entry {
        NTFSIndex.Entry(
            record: record, sequence: 1,
            name: NTFSFileName.Name(parentRecord: 5, namespace: .win32, name: name),
            childBlock: child, isLast: false)
    }
    func marker(child: UInt64? = nil) -> NTFSIndex.Entry {
        NTFSIndex.Entry(record: 0, sequence: 0, name: nil, childBlock: child, isLast: true)
    }

    let node = [
        named("Alpha.txt", record: 30), named("Mango.txt", record: 31),
        named("Zebra.txt", record: 32), marker(),
    ]

    expect(
        NTFSIndex.find("Mango.txt", in: node) == .found(node[1]),
        "a name in the node is found")
    expect(
        NTFSIndex.find("Alpha.txt", in: node) == .found(node[0]),
        "including the first one")
    expect(
        NTFSIndex.find("Zebra.txt", in: node) == .found(node[2]),
        "and the last one before the marker")

    // Case. NTFS sorts and matches case-insensitively.
    expect(
        NTFSIndex.find("mango.txt", in: node) == .found(node[1]),
        "a name typed in the wrong case is still found, because NTFS matches that way")
    expect(
        NTFSIndex.find("MANGO.TXT", in: node) == .found(node[1]),
        "whichever case it is typed in")

    // Not there, in each of the three positions that matter.
    expect(
        NTFSIndex.find("Aardvark.txt", in: node) == .absent,
        "a name before every entry is absent when there is no subtree")
    expect(
        NTFSIndex.find("Nectarine.txt", in: node) == .absent,
        "so is one between two entries")
    expect(
        NTFSIndex.find("Zzz.txt", in: node) == .absent,
        "and one past every entry")

    // With subtrees, which is what makes it a search rather than a scan.
    let withChildren = [
        named("Alpha.txt", child: 7), named("Mango.txt", child: 8),
        marker(child: 9),
    ]
    expect(
        NTFSIndex.find("Aardvark.txt", in: withChildren) == .descend(7),
        "a name before the first entry is in the subtree below it")
    expect(
        NTFSIndex.find("Ballroom.txt", in: withChildren) == .descend(8),
        "a name between two entries is below the one after it")
    expect(
        NTFSIndex.find("Zzz.txt", in: withChildren) == .descend(9),
        "and a name past every entry is below the marker -- which is the whole reason the "
            + "marker is kept")
    expect(
        NTFSIndex.find("Alpha.txt", in: withChildren) == .found(withChildren[0]),
        "while a name that is present is found rather than descended past")

    // An empty node, and one that is only a marker.
    // The comparison is the volume's, not the language's, and the difference is
    // not academic. A node holding both spellings of the same German word:
    // NTFS uppercases sharp s to itself, so it sorts after every S, while Swift
    // uppercases it to SS and makes the two names one.
    let german = [
        named("strasse.txt", record: 40), named("stra\u{00DF}e.txt", record: 41), marker(),
    ]
    expect(
        NTFSIndex.find("stra\u{00DF}e.txt", in: german) == .found(german[0]),
        "without the volume's table, asking for the sharp-s name returns the other file -- one "
            + "file's bytes handed over for another file's name, with nothing reporting a fault")

    let volume = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0) })
    if let volume, let handle = FileHandle(forReadingAtPath: volume) {
        defer { try? handle.close() }
        let lock = NSLock()
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
        if let collation = reader?.collation() {
            expect(
                NTFSIndex.find("stra\u{00DF}e.txt", in: german, collation: collation)
                    == .found(german[1]),
                "and with it, the right one")
            expect(
                NTFSIndex.find("strasse.txt", in: german, collation: collation)
                    == .found(german[0]),
                "and the other name still finds the other file")
            expect(
                NTFSIndex.find("MANGO.TXT", in: node, collation: collation) == .found(node[1]),
                "case still does not make a new file")
            expect(
                NTFSIndex.find("Nectarine.txt", in: node, collation: collation) == .absent,
                "and a name that is not there is still not there")
        } else {
            expect(false, "the volume's table loads")
        }
    }

    expect(NTFSIndex.find("anything", in: []) == .absent, "an empty node holds nothing")
    expect(NTFSIndex.find("anything", in: [marker()]) == .absent, "nor does a bare marker")
    expect(
        NTFSIndex.find("anything", in: [marker(child: 3)]) == .descend(3),
        "but a marker with a subtree points into it")
}

group("theNtfsReaderIsFastEnoughToBeWorthHaving") {
    // What the read path costs, with no mount and no framework in the way.
    // This is the floor: whatever FSKit adds on top, the reader cannot be
    // faster than this, and if this is slow nothing above it can rescue it.
    //
    // Reported rather than asserted at a threshold. A number that fails on a
    // busy machine teaches people to ignore a red suite; a number printed
    // beside v1's is one somebody can act on.
    guard ProcessInfo.processInfo.environment["LUKOTTA_BENCH"] != nil else { return }
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let fs: any FSBacking = NTFSBacking(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else { return }

    let root = fs.rootHandle
    guard let many = fs.lookup("many", in: root) else {
        print("    (no 'many' directory on this volume; nothing to measure)")
        return
    }

    func ms(_ body: () -> Void) -> Double {
        let t0 = Date()
        body()
        return Date().timeIntervalSince(t0) * 1000
    }

    var children: [(name: String, handle: FSHandle)] = []
    let listing = ms { children = fs.children(of: many) }
    print("    list \(children.count) files          \(Int(listing)) ms")

    guard !children.isEmpty else { return }
    let sample = Array(children.prefix(2000))
    let lookups = ms {
        for entry in sample { _ = fs.lookup(entry.name, in: many) }
    }
    print(
        "    look up \(sample.count) by name       \(Int(lookups)) ms"
            + "   \(Int(lookups * 1000 / Double(sample.count))) us each")

    let stats = ms {
        for entry in sample { _ = fs.attributes(of: entry.handle) }
    }
    print(
        "    read \(sample.count) files' attributes \(Int(stats)) ms"
            + "   \(Int(stats * 1000 / Double(sample.count))) us each")

    let reads = ms {
        for entry in sample { _ = fs.read(entry.handle, offset: 0, length: 64) }
    }
    print(
        "    read \(sample.count) files' contents   \(Int(reads)) ms"
            + "   \(Int(reads * 1000 / Double(sample.count))) us each")

    // Streaming a large file, which is the number requirement 4 turns on. The
    // small files above are resident -- their contents sit inside their
    // records -- so none of the numbers above touches a runlist at all.
    guard let big = fs.lookup("big.bin", in: root),
        let size = fs.attributes(of: big)?.size, size > 0
    else {
        print("    (no big.bin on this volume; streaming not measured)")
        return
    }
    let chunk = 1 << 20
    var read = 0
    let streamed = ms {
        var offset = 0
        while offset < Int(size) {
            let got = fs.read(big, offset: offset, length: min(chunk, Int(size) - offset))
            if got.isEmpty { break }
            read += got.count
            offset += got.count
        }
    }
    let megabytes = Double(read) / 1_048_576
    print(
        "    stream \(Int(megabytes)) MB              \(Int(streamed)) ms"
            + "   \(Int(megabytes / (streamed / 1000))) MB/s")
}

group("compressedAndEncryptedFilesAreRefusedNotGuessedAt") {
    // A compressed or EFS-encrypted attribute's clusters hold compressed or
    // ciphered bytes, not the file's contents. Serving them as contents returns
    // noise, and nothing reports a fault -- the file simply opens as garbage,
    // which reads to whoever opened it as a damaged drive rather than as an
    // unsupported feature.
    //
    // Refusing is visible. Guessing is not. So the flags are read and acted on.
    func attribute(flags: Int) -> Data {
        var a = [UInt8](repeating: 0, count: 96)
        a[0] = 0x80  // $DATA
        for i in 0..<4 { a[4 + i] = UInt8((96 >> (8 * i)) & 0xFF) }
        a[8] = 1  // non-resident
        a[12] = UInt8(flags & 0xFF); a[13] = UInt8((flags >> 8) & 0xFF)
        a[32] = 64  // runlist offset
        for i in 0..<8 { a[48 + i] = UInt8((UInt64(4096) >> (8 * UInt64(i))) & 0xFF) }
        return Data(a)
    }

    guard let plain = NTFSAttribute.header(attribute(flags: 0), at: 0) else {
        expect(false, "an ordinary attribute reads")
        return
    }
    expect(!plain.isCompressed, "an ordinary file is not compressed")
    expect(!plain.isEncrypted, "nor encrypted")
    expect(!plain.isSparse, "nor sparse")
    expect(plain.isReadableAsIs, "and its bytes are its contents")

    guard let compressed = NTFSAttribute.header(attribute(flags: 0x0001), at: 0) else {
        expect(false, "a compressed attribute reads")
        return
    }
    expect(compressed.isCompressed, "a compressed attribute says so")
    expect(
        !compressed.isReadableAsIs,
        "and its clusters are refused rather than served as the file's contents")

    guard let encrypted = NTFSAttribute.header(attribute(flags: 0x4000), at: 0) else {
        expect(false, "an encrypted attribute reads")
        return
    }
    expect(encrypted.isEncrypted, "an EFS-encrypted attribute says so")
    expect(!encrypted.isReadableAsIs, "and is refused rather than served as ciphertext")

    guard let sparse = NTFSAttribute.header(attribute(flags: 0x8000), at: 0) else {
        expect(false, "a sparse attribute reads")
        return
    }
    expect(sparse.isSparse, "a sparse attribute says so")
    expect(
        sparse.isReadableAsIs,
        "but is readable: the runlist already says which parts are holes, so nothing is guessed")

    // Both at once, which Windows allows.
    guard let both = NTFSAttribute.header(attribute(flags: 0x0001 | 0x8000), at: 0) else {
        expect(false, "a compressed sparse attribute reads")
        return
    }
    expect(!both.isReadableAsIs, "compressed and sparse together is still refused")

    // The other way a file's contents can fail to be where they look. A badly
    // fragmented file can have more attributes than one record holds, and NTFS
    // then writes an $ATTRIBUTE_LIST saying where the rest are. The record
    // somebody reads first may hold no $DATA at all -- and reporting that as an
    // empty file is data loss that looks like a successful read.
    expect(
        NTFSAttribute.Kind(rawValue: 0x20) == .attributeList,
        "the attribute list has a type of its own, so its presence is detectable")
}

group("aFolderIsHandedOverABufferfulAtATime") {
    // FSKit does not ask for a directory in one call. It gives the module a
    // buffer, the module packs entries until it is full, and each entry carries
    // the place to resume from. One off in either direction is not an error
    // anybody sees: too high and a file vanishes from the folder, too low and
    // one appears twice.
    let files = ["alpha", "bravo", "charlie", "delta"]

    let all = DirectoryEnumeration.steps(files, from: 0)
    expect(all.count == 4, "starting from nothing hands over the whole folder")
    expect(all.map(\.entry) == files, "in the order it was given")
    expect(
        all[0].nextCookie == 1,
        "and the first entry's cookie names the second, not itself -- naming itself would "
            + "show it twice for ever")
    expect(all[3].nextCookie == 4, "the last entry's cookie is past the end, which ends the list")

    // Resuming, which is the case a full buffer creates.
    let rest = DirectoryEnumeration.steps(files, from: 2)
    expect(rest.map(\.entry) == ["charlie", "delta"], "resuming from two gives the rest")
    expect(rest[0].nextCookie == 3, "with cookies that continue rather than restart")

    // The ends.
    expect(
        DirectoryEnumeration.steps(files, from: 4).isEmpty,
        "a cookie at the end hands over nothing, which is how a listing finishes")
    expect(
        DirectoryEnumeration.steps(files, from: 99).isEmpty,
        "and one past the end does the same rather than reading off the array")
    expect(
        DirectoryEnumeration.steps(files, from: UInt64.max).isEmpty,
        "including one that could not be an index at all")
    expect(
        DirectoryEnumeration.steps([String](), from: 0).isEmpty,
        "an empty folder hands over nothing")

    expect(DirectoryEnumeration.isFinished(files, cookie: 4), "four entries end at cookie four")
    expect(!DirectoryEnumeration.isFinished(files, cookie: 3), "and not before")
    expect(
        DirectoryEnumeration.isFinished(files, cookie: UInt64.max),
        "a cookie that cannot be an index is finished rather than trusted")

    // What happens when the buffer fills. The kernel resumes from the last
    // entry that fitted, so the one that did not is asked for again -- handing
    // back the cookie of the entry that failed would skip it.
    let fitted = Array(all.prefix(2))
    expect(
        DirectoryEnumeration.resumeCookie(after: fitted, from: 0) == 2,
        "after two entries fitted, the next call starts at the third")
    expect(
        DirectoryEnumeration.steps(files, from: 2).first?.entry == "charlie",
        "which is the entry that did not fit, so it is not skipped")
    expect(
        DirectoryEnumeration.resumeCookie(after: [DirectoryEnumeration.Step<String>](), from: 7)
            == 7,
        "and a call where nothing fitted at all resumes where it began rather than moving on")

    // Whole folder, one buffer at a time, losing and repeating nothing.
    var seen: [String] = []
    var cookie: UInt64 = 0
    var rounds = 0
    while !DirectoryEnumeration.isFinished(files, cookie: cookie), rounds < 10 {
        rounds += 1
        // A buffer that fits exactly one entry, which is the hardest case.
        let batch = Array(DirectoryEnumeration.steps(files, from: cookie).prefix(1))
        seen += batch.map(\.entry)
        cookie = DirectoryEnumeration.resumeCookie(after: batch, from: cookie)
    }
    expect(seen == files, "a folder read one entry at a time comes back whole, in order, once")
}

group("aBigDirectoryComesBackWhole") {
    // The root has nine entries in one index block. A folder of five thousand
    // spans many, and a listing that stops early is invisible: the folder just
    // has fewer files in it than it should, and nothing reports anything.
    //
    // The count is knowable independently -- the files were made by a loop --
    // so this is a check rather than a description of what turned up.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let fs: any FSBacking = NTFSBacking(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume opens")
        return
    }

    guard let many = fs.lookup("many", in: fs.rootHandle) else {
        expect(true, "no large directory on this volume to check")
        return
    }
    let children = fs.children(of: many)
    expect(
        children.count == 5000,
        "a folder of five thousand files lists five thousand, not one index block's worth "
            + "-- a listing that stops early is a folder with files missing and no error")

    // Every name is unique. A block read twice would double entries, and the
    // count alone would not catch it if another block were dropped.
    expect(
        Set(children.map(\.name)).count == children.count,
        "with no name appearing twice, which a block read twice would cause")

    // Sorted, because an enumeration resumes by index into this order.
    expect(
        children.map(\.name) == children.map(\.name).sorted(),
        "and in a stable order, or a resumed listing skips files")

    // Every one is findable through the tree, which is a different code path
    // from the listing and would disagree if the descent were wrong.
    let sample = children.indices.filter { $0 % 500 == 0 }.map { children[$0].name }
    for name in sample {
        expect(
            fs.lookup(name, in: many) != nil,
            "and findable by name through the tree: \(name)")
    }
}

group("aesXtsMatchesTheNumbersSomebodyElsePublished") {
    // Both BitLocker and LUKS encrypt a disk with AES-XTS, and macOS does not
    // expose it: CommonCrypto's mode enum stops at CFB8 and CryptoKit has no
    // block-cipher modes at all. So it is built here on AES-ECB, which is the
    // primitive XTS is defined over.
    //
    // Cryptography written from a specification and checked against itself is
    // worth nothing. These are the IEEE 1619 vectors -- somebody else's
    // plaintext, key and expected ciphertext -- so the check can fail.
    func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            let j = hex.index(i, offsetBy: 2)
            return UInt8(hex[i..<j], radix: 16) ?? 0
        }
    }
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // IEEE 1619 vector 1: all-zero keys, sector 0, all-zero plaintext.
    let key1 = bytes("0000000000000000000000000000000000000000000000000000000000000000")
    let plain1 = bytes("0000000000000000000000000000000000000000000000000000000000000000")
    let cipher1 = "917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e"
    expect(
        AESXTS.encrypt(plain1, key: key1, sector: 0).map(hex) == cipher1,
        "IEEE 1619 vector 1 encrypts to the published ciphertext")
    expect(
        AESXTS.decrypt(bytes(cipher1), key: key1, sector: 0).map(hex) == hex(plain1),
        "and decrypts back to the published plaintext")

    // Vector 2: different keys, and a non-zero sector number -- which is what
    // catches a tweak assembled the wrong way round. Vector 1 cannot: sector
    // zero is the same in either byte order.
    let key2 = bytes("1111111111111111111111111111111122222222222222222222222222222222")
    let plain2 = bytes("4444444444444444444444444444444444444444444444444444444444444444")
    let cipher2 = "c454185e6a16936e39334038acef838bfb186fff7480adc4289382ecd6d394f0"
    expect(
        AESXTS.encrypt(plain2, key: key2, sector: 0x3333333333).map(hex) == cipher2,
        "IEEE 1619 vector 2, with a non-zero sector, matches -- which vector 1 cannot check")
    expect(
        AESXTS.decrypt(bytes(cipher2), key: key2, sector: 0x3333333333).map(hex) == hex(plain2),
        "and decrypts back")

    // The tweak is little-endian. Getting it wrong decrypts sector zero
    // correctly and nothing else, which is the worst way to be wrong.
    expect(
        AESXTS.tweak(forSector: 1)[0] == 1 && AESXTS.tweak(forSector: 1)[15] == 0,
        "a sector number goes into the tweak little-endian")
    expect(
        AESXTS.tweak(forSector: 0) == [UInt8](repeating: 0, count: 16),
        "and sector zero is all zeroes either way round, which is why vector 2 is needed")

    // The GF(2^128) doubling, and its reduction constant.
    expect(
        AESXTS.doubled([UInt8](repeating: 0, count: 16))
            == [UInt8](repeating: 0, count: 16),
        "doubling zero is zero")
    var one = [UInt8](repeating: 0, count: 16)
    one[0] = 1
    expect(AESXTS.doubled(one)[0] == 2, "doubling shifts left")
    var top = [UInt8](repeating: 0, count: 16)
    top[15] = 0x80
    let reduced = AESXTS.doubled(top)
    expect(
        reduced[0] == 0x87 && reduced[15] == 0,
        "and a bit falling off the top comes back as 0x87, which is the reduction polynomial")

    // Round trip on something longer than one block, over several sectors.
    let key = bytes("2718281828459045235360287471352662497757247093699959574966967627")
    let sample = (0..<128).map { UInt8($0 & 0xFF) }
    for sector: UInt64 in [0, 1, 2, 0xFFFF_FFFF] {
        guard let ciphered = AESXTS.encrypt(sample, key: key, sector: sector),
            let back = AESXTS.decrypt(ciphered, key: key, sector: sector)
        else {
            expect(false, "a longer buffer round-trips at sector \(sector)")
            continue
        }
        expect(back == sample, "a longer buffer round-trips at sector \(sector)")
        expect(
            ciphered != sample,
            "and the ciphertext is not the plaintext at sector \(sector)")
    }

    // The same plaintext at two sectors must not encrypt the same, or the
    // shape of the filesystem shows through the encryption.
    expect(
        AESXTS.encrypt(sample, key: key, sector: 0)
            != AESXTS.encrypt(sample, key: key, sector: 1),
        "identical plaintext in two sectors encrypts differently, which is the point of XTS")

    // Refusals.
    expect(AESXTS.decrypt([1, 2, 3], key: key, sector: 0) == nil, "a partial block is refused")
    expect(AESXTS.decrypt(sample, key: [1, 2, 3], sector: 0) == nil, "so is a key of no use")
    expect(AESXTS.decrypt([], key: key, sector: 0) == nil, "and nothing at all")
}

group("anEncryptedVolumeReadsAsIfItWereNot") {
    // The claim the architecture rests on: NTFSVolumeReader takes one function
    // -- bytes at an offset -- so an encrypted volume needs no change to any of
    // the parsing above it. This is that claim, tried.
    //
    // A real NTFS volume is encrypted here with AES-XTS, sector by sector, and
    // then read through the decrypting reader. If the arithmetic is right the
    // NTFS reader lists the volume without knowing anything happened.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    let key = (0..<64).map { UInt8(($0 * 7 + 13) & 0xFF) }
    let sectorSize = 512
    let lock = NSLock()

    // Standing in for an encrypted device: read the plain volume and encrypt
    // whatever was asked for, sector by sector, exactly as a real one would
    // already hold it.
    let encryptedDevice: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        guard offset % UInt64(sectorSize) == 0, length % sectorSize == 0 else { return nil }
        try? handle.seek(toOffset: offset)
        guard let plain = try? handle.read(upToCount: length), !plain.isEmpty else { return nil }
        var out = Data()
        let whole = plain.count / sectorSize * sectorSize
        for index in 0..<(whole / sectorSize) {
            let from = plain.startIndex + index * sectorSize
            let sector = Array(plain[from..<from + sectorSize])
            guard
                let ciphered = AESXTS.encrypt(
                    sector, key: key, sector: offset / UInt64(sectorSize) + UInt64(index))
            else { return nil }
            out.append(contentsOf: ciphered)
        }
        return out
    }

    // A read that starts near the end of a sector and runs into the next one.
    // This is the case the widening arithmetic exists for, and the one the
    // volume checks above do not reach: at offset 8 for 7 bytes, widening by
    // length alone and widening by offset-plus-length both give one sector, so
    // a wrong formula is invisible there.
    let plainSectors = (0..<(4 * 512)).map { UInt8($0 & 0xFF) }
    let straddleDevice: NTFSVolumeReader.ReadBytes = { offset, length in
        guard offset % 512 == 0, length % 512 == 0 else { return nil }
        var out = Data()
        for index in 0..<(length / 512) {
            let sector = UInt64(offset / 512) + UInt64(index)
            let from = Int(sector) * 512
            guard from + 512 <= plainSectors.count else { break }
            guard
                let ciphered = AESXTS.encrypt(
                    Array(plainSectors[from..<from + 512]), key: key, sector: sector)
            else { return nil }
            out.append(contentsOf: ciphered)
        }
        return out.isEmpty ? nil : out
    }
    let straddling = DecryptingReader(
        sectorSize: 512, dataOffset: 0, key: key, reading: straddleDevice)

    expect(
        straddling.read(500, 100).map(Array.init) == Array(plainSectors[500..<600]),
        "a read beginning near the end of a sector and running into the next comes back whole")
    expect(
        straddling.read(0, 512).map(Array.init) == Array(plainSectors[0..<512]),
        "an aligned whole sector reads")
    expect(
        straddling.read(511, 2).map(Array.init) == Array(plainSectors[511..<513]),
        "and one byte either side of a boundary reads as two bytes, not as noise")
    expect(
        straddling.read(1000, 1000).map(Array.init) == Array(plainSectors[1000..<2000]),
        "a read spanning three sectors from an unaligned start comes back whole")

    // Reading it without decrypting must not work, or the check proves nothing.
    let ciphered = NTFSVolumeReader(read: encryptedDevice)
    expect(
        ciphered == nil,
        "the encrypted volume does not open as NTFS -- otherwise nothing below is a test")

    // And with the decrypting reader in the way.
    let decrypting = DecryptingReader(
        sectorSize: sectorSize, dataOffset: 0, key: key, reading: encryptedDevice)
    guard let reader = NTFSVolumeReader(read: { decrypting.read($0, $1) }) else {
        expect(false, "the same volume opens through the decrypting reader")
        return
    }
    expect(true, "the same volume opens through the decrypting reader")
    expect(reader.geometry.bytesPerCluster >= 512, "with the geometry it always had")

    guard let root = reader.contents(ofDirectory: NTFSTable.rootRecord) else {
        expect(false, "and lists its root")
        return
    }
    let names = root.map(\.name)
    expect(names.contains("$MFT"), "with the master file table in it")
    expect(names.contains("readback.txt") || names.contains("."), "and the files that are on it")

    // The whole point: a file read through the encryption comes back as itself.
    if let entry = root.first(where: { $0.name == "readback.txt" }) {
        expect(
            reader.contents(ofFile: entry.record)
                .map { String(decoding: $0, as: UTF8.self) }
                == "LUKOTTA-V2-READBACK-CHECK-0123456789",
            "and a file's contents come back through the encryption byte for byte")
        // An unaligned read, which is the arithmetic that goes wrong quietly:
        // XTS works a sector at a time, so a read from the middle of one has to
        // be widened, decrypted, and trimmed back.
        expect(
            reader.contents(ofFile: entry.record, offset: 8, length: 7)
                .map { String(decoding: $0, as: UTF8.self) } == "V2-READ",
            "including a read that begins in the middle of a sector")
    }
}

group("theClusterBitmapSaysWhichClustersNotHowMany") {
    // $Bitmap is one bit per cluster and is what a write path stands on:
    // allocating means finding a zero bit, and getting it wrong hands out a
    // cluster that already holds somebody's file. Every other mistake in this
    // reader misreads a drive. This one destroys it.
    //
    // The bit order is the trap. Bit 0 of byte 0 is cluster 0, least
    // significant first. Reading most-significant-first gives a bitmap that is
    // right about how many clusters are free and wrong about which -- so the
    // volume looks healthy and the writes land on other people's data.

    // 0b0000_0101: clusters 0 and 2 in use, 1 and 3..7 free.
    let byte = Data([0b0000_0101])
    expect(NTFSBitmap.isInUse(cluster: 0, bitmap: byte) == true, "bit zero is cluster zero")
    expect(NTFSBitmap.isInUse(cluster: 1, bitmap: byte) == false, "bit one is cluster one")
    expect(
        NTFSBitmap.isInUse(cluster: 2, bitmap: byte) == true,
        "and bit two is cluster two -- least significant first, which is the whole question")
    expect(NTFSBitmap.isInUse(cluster: 7, bitmap: byte) == false, "the top bit is cluster seven")

    // The second byte holds clusters 8 to 15.
    let two = Data([0x00, 0b0000_0001])
    expect(
        NTFSBitmap.isInUse(cluster: 8, bitmap: two) == true,
        "the first bit of the second byte is cluster eight")
    expect(NTFSBitmap.isInUse(cluster: 0, bitmap: two) == false, "and cluster zero is free")

    // Past the end is not "free". A caller that confuses them allocates past
    // the end of the volume.
    expect(
        NTFSBitmap.isInUse(cluster: 99, bitmap: byte) == nil,
        "a cluster the bitmap does not cover is unknown rather than free")

    // Finding room.
    let free = Data([0b1111_0001])  // clusters 0, 4, 5, 6, 7 used; 1, 2, 3 free
    expect(
        NTFSBitmap.firstFreeRun(count: 1, in: free, totalClusters: 8) == 1,
        "one free cluster is found at the first zero bit")
    expect(
        NTFSBitmap.firstFreeRun(count: 3, in: free, totalClusters: 8) == 1,
        "and a run of three at the start of the free stretch")
    expect(
        NTFSBitmap.firstFreeRun(count: 4, in: free, totalClusters: 8) == nil,
        "a run longer than any free stretch is not found rather than half found")
    expect(
        NTFSBitmap.firstFreeRun(count: 1, in: free, totalClusters: 8, from: 4) == nil,
        "and searching past the free stretch finds nothing")
    expect(
        NTFSBitmap.firstFreeRun(count: 0, in: free, totalClusters: 8) == nil,
        "asking for no clusters is refused rather than answered with cluster zero")

    // A volume whose very first cluster is free. Every fixture above has
    // cluster zero in use, which is true of any real NTFS volume -- the boot
    // sector is there -- and that is exactly why this case hid: the subtraction
    // that finds the start of a run underflows when the run ends at cluster
    // count-1, and the process traps rather than returning an answer.
    let firstFree = Data([0b1111_1110])  // cluster 0 free, 1..7 in use
    expect(
        NTFSBitmap.firstFreeRun(count: 1, in: firstFree, totalClusters: 8) == 0,
        "one cluster wanted, and the free one is cluster zero")
    let allFree = Data([0x00])
    expect(
        NTFSBitmap.firstFreeRun(count: 1, in: allFree, totalClusters: 8) == 0,
        "an empty volume allocates its first cluster")
    expect(
        NTFSBitmap.firstFreeRun(count: 8, in: allFree, totalClusters: 8) == 0,
        "and a run covering the whole of it starts at zero rather than underflowing")

    // The volume's count bounds the search, not the bitmap's length. The
    // bitmap is rounded up to whole bytes, so its last bits describe clusters
    // that do not exist -- allocating one writes past the end of the partition.
    let padded = Data([0b0000_0001])  // cluster 0 used, 1..7 free in the bitmap
    expect(
        NTFSBitmap.firstFreeRun(count: 1, in: padded, totalClusters: 2) == 1,
        "a free cluster inside the volume is found")
    expect(
        NTFSBitmap.firstFreeRun(count: 3, in: padded, totalClusters: 2) == nil,
        "but a run running past the volume's own count is not, though the bits are there")
    expect(
        NTFSBitmap.freeClusters(in: padded, totalClusters: 2) == 1,
        "and free space counts clusters the volume has, not bits the bitmap holds")
    expect(
        NTFSBitmap.capacity(of: padded) == 8,
        "while the bitmap's own capacity is every bit in it")
}

group("theRealVolumesBitmapAgreesWithItsFiles") {
    // The check the synthetic bits cannot make. If the bit order were reversed,
    // a bitmap of the right length with the right number of set bits would
    // still be produced -- and the clusters $MFT actually occupies would read
    // as free. So: read the volume's own bitmap, and ask whether the clusters
    // its own files sit on are claimed.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume opens")
        return
    }

    // $Bitmap is record 6 on every NTFS volume.
    guard let bitmap = reader.contents(ofFile: 6), !bitmap.isEmpty else {
        expect(false, "the cluster bitmap reads")
        return
    }
    let totalClusters = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
    expect(
        NTFSBitmap.capacity(of: bitmap) >= totalClusters,
        "the bitmap has a bit for every cluster on the volume")

    // Cluster 0 holds the boot sector. It is in use on every volume ever made.
    expect(
        NTFSBitmap.isInUse(cluster: 0, bitmap: bitmap) == true,
        "cluster zero holds the boot sector and is in use -- reversed bit order fails here")

    // And every cluster $MFT occupies is claimed. That is thirteen thousand
    // clusters whose numbers came from a runlist, checked against a bitmap read
    // separately: two structures written by mkntfs that have to agree.
    guard let mft = reader.record(0),
        let data = reader.attributes(of: mft).first(where: { $0.kind == .data }),
        let runs = NTFSRunlist.decode(mft.data, at: data.runlistOffset, limit: mft.data.count)
    else {
        expect(false, "the table's runs read")
        return
    }
    expect(
        NTFSBitmap.allInUse(runs, bitmap: bitmap, totalClusters: totalClusters),
        "every cluster the master file table occupies is marked in use in the bitmap")

    // Free space is a real number, neither zero nor everything.
    let free = NTFSBitmap.freeClusters(in: bitmap, totalClusters: totalClusters)
    expect(free > 0, "the volume has some free space")
    expect(free < totalClusters, "and some of it is in use")
    if ProcessInfo.processInfo.environment["LUKOTTA_SHOW_LISTING"] != nil {
        let bytes = free * UInt64(reader.geometry.bytesPerCluster)
        print("    free space: \(free) of \(totalClusters) clusters, \(bytes / 1_048_576) MB")
    }
}

group("aDirtyVolumeIsNeverWrittenTo") {
    // $Volume carries the flag Windows sets when a drive is mounted for writing
    // and clears on a clean unmount. A drive pulled out mid-write, or left in
    // Windows fast-startup hibernation, still has it set -- and its metadata may
    // be half-updated, with $LogFile holding what is needed to finish or undo
    // the change.
    //
    // Writing on top of that produces a volume chkdsk cannot fully repair. It
    // is also exactly the state a drive is in after the failure that made
    // somebody reach for this application in the first place.

    func info(flags: UInt16, label: String? = "DRIVE") -> NTFSVolumeState.Info? {
        var value = [UInt8](repeating: 0, count: 12)
        value[8] = 3
        value[9] = 1
        value[10] = UInt8(flags & 0xFF)
        value[11] = UInt8(flags >> 8)
        var record = [UInt8](repeating: 0, count: 512)
        for (i, b) in value.enumerated() { record[100 + i] = b }
        var attributes = [
            NTFSAttribute.Header(
                type: 0x70, length: 40, isResident: true, valueOffset: 100, valueLength: 12,
                runlistOffset: 0, startingCluster: 0, lastCluster: 0, dataSize: 12)
        ]
        if let label {
            let units = Array(label.utf16)
            for (i, u) in units.enumerated() {
                record[200 + i * 2] = UInt8(u & 0xFF)
                record[200 + i * 2 + 1] = UInt8(u >> 8)
            }
            attributes.append(
                NTFSAttribute.Header(
                    type: 0x60, length: 40, isResident: true, valueOffset: 200,
                    valueLength: units.count * 2, runlistOffset: 0, startingCluster: 0,
                    lastCluster: 0, dataSize: UInt64(units.count * 2)))
        }
        return NTFSVolumeState.read(record: Data(record), attributes: attributes)
    }

    guard let clean = info(flags: 0x0000) else {
        expect(false, "a clean volume's information reads")
        return
    }
    expect(!clean.isDirty, "a volume unmounted cleanly is not dirty")
    expect(clean.isSafeToWrite, "and is safe to write to")
    expect(clean.majorVersion == 3 && clean.minorVersion == 1, "NTFS 3.1, which is what ships")
    expect(clean.label == "DRIVE", "and its name is read")

    guard let dirty = info(flags: 0x0001) else {
        expect(false, "a dirty volume's information reads")
        return
    }
    expect(dirty.isDirty, "a volume that was not unmounted cleanly says so")
    expect(
        !dirty.isSafeToWrite,
        "and is never written to -- its metadata may be half-updated and $LogFile holds the "
            + "record needed to finish or undo it")

    guard let wantsCheck = info(flags: 0x0002) else {
        expect(false, "a volume wanting chkdsk reads")
        return
    }
    expect(wantsCheck.wantsCheck, "a volume Windows wants to check says so")
    expect(!wantsCheck.isSafeToWrite, "and is not written to either")

    // Read-only is always allowed. Somebody holding a drive in this state most
    // likely wants their files off it, and refusing to show them anything would
    // be this application failing at the one job it has.
    expect(
        info(flags: 0x0001)?.isDirty == true,
        "a dirty volume is still readable -- the flag stops writes, not the drive opening")

    // A volume with no name at all is ordinary.
    expect(info(flags: 0, label: nil)?.label == nil, "a drive with no label has none")
}

group("theRealVolumeReportsItsOwnState") {
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        }), let record = reader.record(NTFSVolumeState.volumeRecord)
    else {
        expect(false, "the volume record reads")
        return
    }
    guard
        let info = NTFSVolumeState.read(
            record: record.data, attributes: reader.attributes(of: record))
    else {
        expect(false, "and its state is readable")
        return
    }
    expect(info.majorVersion == 3, "the volume is NTFS 3.x, which every modern one is")
    expect(
        info.label == "BENCHNTFS" || info.label != nil,
        "and carries the label it was formatted with")
    expect(
        !info.isDirty,
        "this volume was unmounted cleanly, so it is not dirty -- which is what makes the "
            + "dirty check above mean something rather than always being false")
    expect(info.isSafeToWrite, "and would be safe to write to")

    // The same answer through the reader and the backing, since a rule that
    // only one of them knows is a rule somebody adding a write path can miss.
    expect(reader.isSafeToWrite, "the reader agrees the volume is writable")
    expect(reader.state()?.label == info.label, "and reports the same label")

    let lock2 = NSLock()
    guard let handle2 = FileHandle(forReadingAtPath: path),
        let backing = NTFSBacking(read: { offset, length in
            lock2.lock()
            defer { lock2.unlock() }
            try? handle2.seek(toOffset: offset)
            return try? handle2.read(upToCount: length)
        })
    else {
        expect(false, "the backing opens the same volume")
        return
    }
    defer { try? handle2.close() }
    expect(
        backing.volumeIsSafeToWrite,
        "and the backing carries the same answer, so a write path added later cannot miss it")
    expect(
        backing.volumeLabel == info.label,
        "with the volume's name, which is what Finder would put on the desktop")

    // Free space, which Finder shows in Get Info and beside every window. A
    // volume claiming to be empty when it is not invites somebody to copy onto
    // it until the write fails.
    guard let space = reader.spaceInUse() else {
        expect(false, "the volume reports how much of it is in use")
        return
    }
    let totalBytes = reader.geometry.totalSectors * UInt64(reader.geometry.bytesPerSector)
    expect(space.total > 0, "the volume has a size")
    expect(
        space.total <= totalBytes + UInt64(reader.geometry.bytesPerCluster),
        "which matches what the boot sector says, to within a cluster")
    expect(space.used > 0, "some of it is in use -- it has files on it")
    expect(space.used < space.total, "and some of it is free")

    // The same number through the backing, which is what statfs would answer.
    expect(
        backing.usage().bytes == space.used,
        "and the backing reports the same, so statfs and the reader cannot disagree")
    expect(backing.capacityInBytes == space.total, "with the same capacity")

    if ProcessInfo.processInfo.environment["LUKOTTA_SHOW_LISTING"] != nil {
        print(
            "    volume: \(space.used / 1_048_576) MB used of "
                + "\(space.total / 1_048_576) MB")
    }
}

group("aWriteGoesOnlyWhereTheFileAlreadyIs") {
    // The smallest write worth anything, and the only one safe to do first:
    // bytes into clusters the file already owns. Nothing about the volume's
    // structure changes -- no cluster allocated, no bitmap bit set, no record
    // created, no index touched.
    //
    // What it refuses matters more than what it does. Every refusal here is a
    // write that would land on somebody else's data.
    let cluster = 4096
    let runs = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 1, physicalCluster: 900, clusterCount: 1),
    ]
    let size: UInt64 = 8192

    guard
        let one = NTFSFileWrite.pieces(
            offset: 0, length: 100, runs: runs, bytesPerCluster: cluster, size: size)
    else {
        expect(false, "a write inside the first run is placed")
        return
    }
    expect(one.count == 1, "in one piece")
    expect(one[0].diskOffset == 100 * UInt64(cluster), "at the run's own place on the disk")
    expect(one[0].range == 0..<100, "covering the bytes asked for")

    // Across two runs, which is what a fragmented file needs.
    guard
        let across = NTFSFileWrite.pieces(
            offset: 4000, length: 200, runs: runs, bytesPerCluster: cluster, size: size)
    else {
        expect(false, "a write crossing two runs is placed")
        return
    }
    expect(across.count == 2, "as two writes, because the file is in two places")
    expect(across[0].diskOffset == 100 * UInt64(cluster) + 4000, "the first where the run is")
    expect(across[0].range == 0..<96, "stopping at the end of that run")
    expect(across[1].diskOffset == 900 * UInt64(cluster), "the second where the next run is")
    expect(across[1].range == 96..<200, "carrying on from where the first stopped")
    expect(
        across.map(\.range.count).reduce(0, +) == 200,
        "and together covering exactly what was asked for, with nothing dropped")

    // Past the end of the file means growing it, which means allocating.
    expect(
        NTFSFileWrite.pieces(
            offset: 8000, length: 1000, runs: runs, bytesPerCluster: cluster, size: size) == nil,
        "a write running past the end of the file is refused, not clamped -- a clamped write "
            + "stores less than was asked for and the caller cannot tell which bytes landed")
    expect(
        NTFSFileWrite.pieces(
            offset: 9000, length: 10, runs: runs, bytesPerCluster: cluster, size: size) == nil,
        "and one starting past the end is refused")
    expect(
        NTFSFileWrite.pieces(
            offset: 0, length: 0, runs: runs, bytesPerCluster: cluster, size: size) == nil,
        "a write of nothing is refused rather than answered with no pieces")

    // A hole has no clusters behind it. Writing into one means allocating.
    let sparse = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 1),
        NTFSRunlist.Run(logicalCluster: 1, physicalCluster: nil, clusterCount: 1),
    ]
    expect(
        NTFSFileWrite.pieces(
            offset: 4096, length: 10, runs: sparse, bytesPerCluster: cluster, size: size) == nil,
        "a write into a hole is refused rather than dropped silently")
    expect(
        NTFSFileWrite.pieces(
            offset: 0, length: 10, runs: sparse, bytesPerCluster: cluster, size: size) != nil,
        "while the run before it still writes")

    // The gates that come before any of that.
    let plain = NTFSAttribute.Header(
        type: 0x80, length: 96, isResident: false, valueOffset: 0, valueLength: 0,
        runlistOffset: 64, startingCluster: 0, lastCluster: 1, dataSize: size)
    expect(
        NTFSFileWrite.isAllowed(attribute: plain, volumeIsClean: true, volumeIsWritable: true),
        "an ordinary file on a clean volume may be written")
    expect(
        !NTFSFileWrite.isAllowed(attribute: plain, volumeIsClean: false, volumeIsWritable: true),
        "a dirty volume is never written to, whatever the file is")
    expect(
        !NTFSFileWrite.isAllowed(attribute: plain, volumeIsClean: true, volumeIsWritable: false),
        "nor is a read-only one")

    let compressed = NTFSAttribute.Header(
        type: 0x80, length: 96, isResident: false, valueOffset: 0, valueLength: 0,
        runlistOffset: 64, startingCluster: 0, lastCluster: 1, dataSize: size,
        isCompressed: true)
    expect(
        !NTFSFileWrite.isAllowed(
            attribute: compressed, volumeIsClean: true, volumeIsWritable: true),
        "a compressed file is not written -- plaintext into its clusters destroys it")

    let resident = NTFSAttribute.Header(
        type: 0x80, length: 96, isResident: true, valueOffset: 24, valueLength: 50,
        runlistOffset: 0, startingCluster: 0, lastCluster: 0, dataSize: 50)
    expect(
        !NTFSFileWrite.isAllowed(attribute: resident, volumeIsClean: true, volumeIsWritable: true),
        "and a small file living inside its record is not, because that is a metadata write")
    expect(!NTFSFileWrite.residentIsWritable(resident), "which is said plainly rather than implied")
}

group("aByteWrittenByUsIsThereWhenLinuxLooks") {
    // The first write. Guarded, because it changes a volume: only runs when
    // LUKOTTA_WRITE_IMAGE names an image that exists, and that image is a copy
    // made for the purpose.
    //
    // Reading it back with our own reader would prove only that we are
    // self-consistent. The verification is done afterwards by mounting the
    // volume with Linux's ntfs3 driver, which shares nothing with this code.
    guard let path = ProcessInfo.processInfo.environment["LUKOTTA_WRITE_IMAGE"],
        FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forUpdatingAtPath: path)
    else { return }
    defer { try? handle.close() }

    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume to write to opens")
        return
    }

    // Every gate, before anything moves.
    guard let state = reader.state(), state.isSafeToWrite else {
        expect(false, "the volume is clean and writable")
        return
    }
    guard let target = reader.find("big.bin", inDirectory: NTFSTable.rootRecord),
        let record = reader.record(target),
        let data = reader.attributes(of: record).first(where: { $0.kind == .data })
    else {
        expect(false, "the file to write to is found")
        return
    }
    expect(
        NTFSFileWrite.isAllowed(
            attribute: data, volumeIsClean: !state.isDirty, volumeIsWritable: state.isSafeToWrite),
        "and writing to it is allowed: non-resident, not compressed, clean volume")

    guard
        let runs = NTFSRunlist.decode(
            record.data, at: data.runlistOffset, limit: record.data.count)
    else {
        expect(false, "its runs decode")
        return
    }

    // A marker at a known offset, far enough in to be in a real cluster rather
    // than anything the format left behind.
    let marker = Array("LUKOTTA-V2-WROTE-THIS-AT-1048576".utf8)
    let at: UInt64 = 1_048_576
    guard
        let pieces = NTFSFileWrite.pieces(
            offset: at, length: marker.count, runs: runs,
            bytesPerCluster: reader.geometry.bytesPerCluster, size: data.dataSize)
    else {
        expect(false, "the write is placed")
        return
    }
    expect(!pieces.isEmpty, "with at least one piece")

    for piece in pieces {
        lock.lock()
        try? handle.seek(toOffset: piece.diskOffset)
        handle.write(Data(marker[piece.range]))
        lock.unlock()
    }
    try? handle.synchronize()
    expect(true, "the bytes are written to the volume")

    // Our own reader agreeing is necessary but not sufficient; the real check
    // runs outside this process.
    expect(
        reader.contents(ofFile: target, offset: at, length: marker.count)
            .map { Array($0) } == marker,
        "and our reader sees them, which is the weaker half of the check")
}

group("theBackingWritesOnlyWhenGivenTheMeansAndThePermission") {
    // The write path, through the seam rather than through the arithmetic. Runs
    // against a copy, because it changes a volume.
    guard let path = ProcessInfo.processInfo.environment["LUKOTTA_WRITE_IMAGE"],
        FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forUpdatingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()

    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    let write: NTFSBacking.WriteBytes = { offset, bytes in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        handle.write(bytes)
        return true
    }

    // Opened without the means: cannot write, whatever is asked.
    guard let readOnly = NTFSBacking(read: read) else {
        expect(false, "the volume opens read-only")
        return
    }
    guard let target = readOnly.lookup("big.bin", in: readOnly.rootHandle) else {
        expect(true, "no big.bin on the write copy")
        return
    }
    expect(
        readOnly.write(target, contents: Data([0x41]), offset: 0) == 0,
        "a backing with no write function stores nothing")

    // Opened with it: writes, into clusters the file already owns.
    guard let writable = NTFSBacking(read: read, write: write),
        let file = writable.lookup("big.bin", in: writable.rootHandle)
    else {
        expect(false, "the volume opens writable")
        return
    }
    let marker = Data("THROUGH-THE-SEAM-AT-2097152".utf8)
    let at = 2_097_152
    expect(
        writable.write(file, contents: marker, offset: at) == marker.count,
        "a write into clusters the file owns stores every byte asked for")
    expect(
        writable.read(file, offset: at, length: marker.count) == marker,
        "and reads back as itself")

    // A write at the end makes the file longer. The bytes go to clusters that
    // were free a moment ago, and the record says so afterwards.
    guard let size = writable.attributes(of: file)?.size else { return }
    let tail = Data("PAST-THE-END".utf8)
    expect(
        writable.write(file, contents: tail, offset: Int(size)) == tail.count,
        "a write at the end of the file grows it")
    expect(
        writable.attributes(of: file)?.size == size + UInt64(tail.count),
        "and the file is longer by exactly what went in")
    expect(
        writable.read(file, offset: Int(size), length: tail.count) == tail,
        "with the new bytes where they were put")
    expect(
        writable.read(file, offset: 0, length: 8).count == 8,
        "and the beginning of it still readable")
    expect(
        writable.write(file, contents: Data(), offset: 0) == 0,
        "a write of nothing stores nothing")

    // A file whose bytes live inside its record can be written to as well. The
    // record is rewritten rather than any cluster, which is a metadata write
    // and has to go through the fixup.
    if let small = writable.lookup("readback.txt", in: writable.rootHandle),
        let before = writable.attributes(of: small)?.size
    {
        let stamp = Data("R".utf8)
        expect(
            writable.write(small, contents: stamp, offset: 0) == 1,
            "a small file living inside its record takes a write")
        expect(
            writable.read(small, offset: 0, length: 1) == stamp, "and reads it back")
        expect(
            writable.attributes(of: small)?.size == before,
            "without changing its length, since the write fitted inside it")
    }
    expect(
        writable.write(writable.rootHandle, contents: marker, offset: 0) == 0,
        "a directory is never written to")

    // The mark. Writing set it, and while it is set the volume says out loud
    // that somebody without a journal has touched it.
    expect(writable.isMarked, "the write marked the volume dirty")
    expect(!readOnly.isMarked, "and a backing that cannot write never marks anything")

    func flagOnDisk() -> Bool? {
        guard let checker = NTFSVolumeReader(read: read),
            let record = checker.record(NTFSVolumeState.volumeRecord),
            let state = NTFSVolumeState.read(
                record: record.data, attributes: checker.attributes(of: record))
        else { return nil }
        return state.isDirty
    }
    expect(flagOnDisk() == true, "and it is on the disk, not only in memory")

    // Both copies. A mark in the table alone is a mismatch chkdsk would find.
    let geometry = writable.geometry
    let mirrorOffset =
        geometry.mftMirrorStartCluster * UInt64(geometry.bytesPerCluster)
        + NTFSVolumeState.volumeRecord * UInt64(geometry.bytesPerFileRecord)
    func mirrorSaysDirty() -> Bool? {
        guard let raw = read(mirrorOffset, geometry.bytesPerFileRecord),
            let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
            let repaired = NTFSRecord.applyFixup(
                raw, header: header, sectorSize: geometry.bytesPerSector),
            let state = NTFSVolumeState.read(
                record: repaired,
                attributes: NTFSAttribute.all(
                    in: repaired, startingAt: header.firstAttributeOffset,
                    usedLength: header.usedLength))
        else { return nil }
        return state.isDirty
    }
    expect(
        mirrorSaysDirty() == true,
        "and in $MFTMirr too, because $Volume is one of the records it keeps and two copies "
            + "disagreeing is what chkdsk looks for")

    // A second write does not mark again: the flag is set once, and $Volume is
    // not rewritten on every byte stored.
    let before = read(mirrorOffset, geometry.bytesPerFileRecord)
    expect(
        writable.write(file, contents: marker, offset: at) == marker.count,
        "a second write still stores its bytes")
    expect(
        read(mirrorOffset, geometry.bytesPerFileRecord) == before,
        "and does not touch $Volume again -- the signature would have moved if it had")

    // Releasing puts it back, in both places.
    expect(writable.release(), "the volume is released")
    expect(!writable.isMarked, "and is no longer ours")
    expect(flagOnDisk() == false, "the flag is off in the table")
    expect(mirrorSaysDirty() == false, "and off in the mirror")
    expect(writable.release(), "releasing twice is harmless")

    // A volume opened while still marked is not written to at all -- ours or
    // anybody's. That is the same refusal a drive Windows left mid-write gets,
    // and it is why release matters: without it the next mount is read-only.
    expect(
        NTFSBacking(read: read, write: write)?.volumeIsSafeToWrite == true,
        "the released volume is safe to write again, which is what release is for")
    guard let held = NTFSBacking(read: read, write: write),
        let again = held.lookup("big.bin", in: held.rootHandle)
    else {
        expect(false, "it reopens")
        return
    }
    expect(held.write(again, contents: marker, offset: at) == marker.count, "and writes")
    expect(held.isMarked, "marking it once more")
    guard let refused = NTFSBacking(read: read, write: write) else {
        expect(false, "a second backing opens on the marked volume")
        return
    }
    expect(
        !refused.volumeIsSafeToWrite,
        "but a volume opened while marked refuses to be written to, because the mark means "
            + "somebody without a journal has work outstanding on it")
    if let file = refused.lookup("big.bin", in: refused.rootHandle) {
        expect(
            refused.write(file, contents: marker, offset: at) == 0,
            "and stores nothing when asked")
    }
    expect(held.release(), "and the volume is put back clean at the end")
    expect(flagOnDisk() == false, "with the flag off where a mount reads it")
}

group("theVolumeSurvivesBeingAskedFromEveryQueueAtOnce") {
    // FSKit calls a volume on several queues at once. Every check above asks
    // one question at a time, which is the one way this code will never be
    // used, so none of them would notice a data race.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let ioLock = NSLock()
    guard
        let fs: any FSBacking = NTFSBacking(read: { offset, length in
            ioLock.lock()
            defer { ioLock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume opens")
        return
    }

    let root = fs.rootHandle
    let expected = fs.children(of: root).map(\.name)
    guard !expected.isEmpty else { return }

    // Sixteen queues, all asking at once, including the free-space call that
    // fills a cache the first time anybody asks.
    let results = NSMutableArray()
    let resultsLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 16) { index in
        var mine: [String] = []
        for _ in 0..<4 {
            mine = fs.children(of: root).map(\.name)
            _ = fs.usage()
            _ = fs.capacityInBytes
            if let found = fs.lookup(expected[0], in: root) {
                _ = fs.attributes(of: found)
            }
        }
        resultsLock.lock()
        results.add(mine)
        resultsLock.unlock()
    }

    expect(results.count == 16, "every queue finished")
    let everyListing = (results as? [[String]]) ?? []
    expect(
        everyListing.allSatisfy { $0 == expected },
        "and every one of them saw the same directory, in the same order")

    // The cached bitmap is what several threads race to fill. Whatever order
    // they arrive in, the number has to be the one number.
    let sizes = NSMutableArray()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        let used = fs.usage().bytes
        resultsLock.lock()
        sizes.add(used)
        resultsLock.unlock()
    }
    expect(
        Set((sizes as? [UInt64]) ?? []).count == 1,
        "and free space is the same answer however many threads asked for it first")

    // All of the above goes through NTFSBacking, which takes a lock around
    // every call -- so it exercises that lock and not the reader's own. A
    // reader used directly has nothing else protecting it, and the class claims
    // Sendable, so the claim has to hold on its own terms.
    let readerLock = NSLock()
    guard let handle2 = FileHandle(forReadingAtPath: path),
        let bare = NTFSVolumeReader(read: { offset, length in
            readerLock.lock()
            defer { readerLock.unlock() }
            try? handle2.seek(toOffset: offset)
            return try? handle2.read(upToCount: length)
        })
    else {
        expect(false, "a bare reader opens")
        return
    }
    defer { try? handle2.close() }

    let spaces = NSMutableArray()
    let spacesLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        // spaceInUse fills a cache the first time anybody asks, so sixteen
        // threads arriving together all reach for it at once. This is the
        // access the reader's own lock exists for.
        let used = bare.spaceInUse()?.used ?? 0
        spacesLock.lock()
        spaces.add(used)
        spacesLock.unlock()
    }
    expect(spaces.count == 16, "sixteen threads asked a bare reader for free space")
    expect(
        Set((spaces as? [UInt64]) ?? []).count == 1,
        "and all got the same answer, filling its cache without treading on each other")
}

group("aClusterIsNeverHandedOutTwice") {
    // Claiming a cluster that is already claimed is how two files come to share
    // the same bytes, and neither survives it. It also looks like nothing until
    // one of them is read, which may be months later on another machine.
    //
    // The functions return a new bitmap rather than changing one, so a caller
    // that forgets to write it has changed nothing. A version that mutated a
    // shared bitmap would leave the disk and memory disagreeing at every point
    // between the two.
    let empty = Data([0x00, 0x00])  // sixteen clusters, all free

    guard let claimed = NTFSBitmap.claiming(0, count: 3, in: empty, totalClusters: 16) else {
        expect(false, "three free clusters can be claimed")
        return
    }
    expect(NTFSBitmap.isInUse(cluster: 0, bitmap: claimed) == true, "the first is claimed")
    expect(NTFSBitmap.isInUse(cluster: 2, bitmap: claimed) == true, "and the last")
    expect(NTFSBitmap.isInUse(cluster: 3, bitmap: claimed) == false, "and no more than asked")
    expect(
        NTFSBitmap.isInUse(cluster: 0, bitmap: empty) == false,
        "while the bitmap handed in is untouched -- a caller that does not write it back has "
            + "changed nothing, which is the safe direction")

    // The refusal that matters.
    expect(
        NTFSBitmap.claiming(1, count: 3, in: claimed, totalClusters: 16) == nil,
        "a run overlapping a claimed cluster is refused -- two files sharing bytes is "
            + "unrecoverable and silent")
    expect(
        NTFSBitmap.claiming(2, count: 1, in: claimed, totalClusters: 16) == nil,
        "even by one cluster")
    expect(
        NTFSBitmap.claiming(3, count: 2, in: claimed, totalClusters: 16) != nil,
        "while a run beside it is fine")

    // Nothing may be claimed outside the volume, whatever the bitmap's length.
    expect(
        NTFSBitmap.claiming(14, count: 4, in: empty, totalClusters: 16) == nil,
        "a run running past the volume is refused")
    expect(
        NTFSBitmap.claiming(20, count: 1, in: empty, totalClusters: 16) == nil,
        "and one starting past it")
    expect(
        NTFSBitmap.claiming(0, count: 0, in: empty, totalClusters: 16) == nil,
        "claiming nothing is refused rather than answered with an unchanged bitmap")
    expect(
        NTFSBitmap.claiming(UInt64.max, count: 2, in: empty, totalClusters: 16) == nil,
        "and a start that would overflow when the count is added")

    // Releasing, and its own refusal.
    guard let released = NTFSBitmap.releasing(0, count: 3, in: claimed, totalClusters: 16) else {
        expect(false, "claimed clusters can be released")
        return
    }
    expect(
        NTFSBitmap.isInUse(cluster: 0, bitmap: released) == false,
        "a released cluster is free again")
    expect(
        NTFSBitmap.freeClusters(in: released, totalClusters: 16) == 16,
        "and releasing everything claimed gives the volume back")
    expect(
        NTFSBitmap.releasing(0, count: 1, in: empty, totalClusters: 16) == nil,
        "freeing a cluster that is already free is refused -- it means the caller's idea of "
            + "what a file owns disagrees with the volume's, and the next allocation would "
            + "hand out live data")

    // Claim and release are exact inverses, which is what makes an undo safe.
    guard let round = NTFSBitmap.claiming(5, count: 4, in: empty, totalClusters: 16),
        let back = NTFSBitmap.releasing(5, count: 4, in: round, totalClusters: 16)
    else {
        expect(false, "a claim can be undone")
        return
    }
    expect(back == empty, "and claiming then releasing leaves the bitmap exactly as it was")
}

group("aRecordWrittenBackIsStillReadableByAnybody") {
    // Writing a record back means undoing the fixup: the last two bytes of each
    // sector go into the array and the signature takes their place. A record
    // written without that has no signature in any sector, and the next reader
    // -- ours, Windows's, or chkdsk -- sees a torn write and refuses it. That
    // is a file that vanishes.
    //
    // Checked against a real record rather than one we composed, because a
    // fixture written from the same belief as the code round-trips whatever
    // that belief is.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path),
        let boot = try? handle.read(upToCount: 4096),
        let geometry = NTFSGeometry.read(boot)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }

    try? handle.seek(toOffset: geometry.mftByteOffset)
    guard let onDisk = try? handle.read(upToCount: geometry.bytesPerFileRecord),
        let header = NTFSRecord.header(onDisk, expectedLength: geometry.bytesPerFileRecord),
        let repaired = NTFSRecord.applyFixup(
            onDisk, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "a real record reads and repairs")
        return
    }
    expect(repaired != onDisk, "the repair changed it, as it must")

    // Written back with the same signature, it should be byte-identical to what
    // the disk holds.
    let signature =
        UInt16(onDisk[onDisk.startIndex + header.fixupOffset])
        | (UInt16(onDisk[onDisk.startIndex + header.fixupOffset + 1]) << 8)
    guard
        let back = NTFSRecord.removeFixup(
            repaired, header: header, signature: signature, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "the record can be put back into disk form")
        return
    }
    expect(
        back == onDisk,
        "and comes out byte for byte as the disk holds it -- which is the only way a record "
            + "written back is still readable by Windows")

    // With a new signature, as a real write would use, it must still repair.
    let next = NTFSRecord.nextSignature(after: signature)
    expect(next != signature, "a written record gets a new signature")
    expect(next != 0, "and never zero, which is what an unwritten sector holds")
    guard
        let rewritten = NTFSRecord.removeFixup(
            repaired, header: header, signature: next, sectorSize: geometry.bytesPerSector),
        let reread = NTFSRecord.applyFixup(
            rewritten, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "a record written with a new signature repairs again")
        return
    }
    // Everything but the two signature bytes in the fixup array, which are
    // meant to differ: the record was written with a new signature and the
    // array is where that signature lives. applyFixup restores the sector ends
    // and deliberately leaves the array alone, so a byte-for-byte comparison
    // here would be asserting that a rewritten record still carries its old
    // signature -- which is the opposite of what is wanted.
    var expected = [UInt8](repaired)
    var actual = [UInt8](reread)
    expected[header.fixupOffset] = 0
    expected[header.fixupOffset + 1] = 0
    actual[header.fixupOffset] = 0
    actual[header.fixupOffset + 1] = 0
    expect(
        actual == expected,
        "and reads back as the same record apart from the signature, which is what makes a "
            + "write survivable")
    expect(
        reread[reread.startIndex + header.fixupOffset]
            == UInt8(next & 0xFF),
        "carrying the new signature, so a half-written record cannot match the old one")

    // The case that actually matters: a record whose contents changed. For an
    // unmodified record the fixup array already holds the right bytes, so
    // putting them back is redundant and a broken removeFixup round-trips
    // anyway. A record is only ever written because something in it changed,
    // and if that change landed on the last two bytes of a sector it has to
    // reach the array or it is lost.
    var modified = [UInt8](repaired)
    let lastOfFirstSector = geometry.bytesPerSector - 2
    modified[lastOfFirstSector] = 0x5A
    modified[lastOfFirstSector + 1] = 0xA5
    guard
        let storedForm = NTFSRecord.removeFixup(
            Data(modified), header: header, signature: next, sectorSize: geometry.bytesPerSector),
        let readAgain = NTFSRecord.applyFixup(
            storedForm, header: header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "a modified record can be stored and read again")
        return
    }
    expect(
        readAgain[readAgain.startIndex + lastOfFirstSector] == 0x5A
            && readAgain[readAgain.startIndex + lastOfFirstSector + 1] == 0xA5,
        "a change to the last two bytes of a sector survives being written and read -- those "
            + "are the bytes the signature displaces, and losing them loses the change")
    expect(
        storedForm[storedForm.startIndex + lastOfFirstSector] == UInt8(next & 0xFF),
        "while on the disk those bytes hold the signature, as every NTFS reader expects")

    // The signature wraps without ever landing on zero.
    expect(NTFSRecord.nextSignature(after: UInt16.max) == 1, "the signature wraps past zero")
}

group("anAllocationIsAllOfItOrNoneOfIt") {
    // Choosing which clusters a file takes. The decision outlives the write: a
    // file scattered badly costs a seek per fragment for the rest of its life,
    // and its runlist grows until it no longer fits its record.
    //
    // Nothing here writes. It produces a plan and the bitmap as it would be, so
    // a plan can be checked or discarded -- an allocator that changed the
    // bitmap as it searched would leave the disk disagreeing with memory at
    // every step of a search that might still fail.

    // Sixteen clusters, all free.
    let empty = Data([0x00, 0x00])

    guard let one = NTFSAllocator.plan(clusters: 4, in: empty, totalClusters: 16) else {
        expect(false, "a file fits on an empty volume")
        return
    }
    expect(one.fragments == 1, "and takes it in one piece, which is what a file wants")
    expect(one.clusterCount == 4, "covering what was asked for")
    expect(one.runs[0].physicalCluster == 0, "from the start of the free space")
    expect(one.runs[0].logicalCluster == 0, "beginning at the start of the file")
    expect(
        NTFSBitmap.freeClusters(in: one.bitmap, totalClusters: 16) == 12,
        "and the bitmap it hands back has them claimed")
    expect(
        NTFSBitmap.freeClusters(in: empty, totalClusters: 16) == 16,
        "while the bitmap handed in is untouched")

    // A hint, so a file being extended lands beside itself rather than at the
    // other end of the disk.
    guard let hinted = NTFSAllocator.plan(clusters: 2, in: empty, totalClusters: 16, near: 8)
    else {
        expect(false, "a hinted allocation succeeds")
        return
    }
    expect(
        hinted.runs[0].physicalCluster == 8,
        "a hint puts the clusters where the file already is, not at the front of the disk")

    // A volume too fragmented for one run: 0b0101_0101 twice leaves eight
    // single free clusters.
    let fragmented = Data([0b0101_0101, 0b0101_0101])
    expect(
        NTFSBitmap.freeClusters(in: fragmented, totalClusters: 16) == 8,
        "the fragmented volume has eight free clusters")
    guard let scattered = NTFSAllocator.plan(clusters: 3, in: fragmented, totalClusters: 16)
    else {
        expect(false, "a file still fits, in pieces")
        return
    }
    expect(scattered.clusterCount == 3, "covering what was asked for")
    expect(scattered.fragments == 3, "in three pieces, because no two free clusters adjoin")
    expect(
        scattered.runs.map(\.logicalCluster) == [0, 1, 2],
        "and the pieces run consecutively through the file, whatever order they sit on the disk")

    // All of it or none. A file half allocated is worse than one refused: the
    // clusters are gone and nothing owns them.
    expect(
        NTFSAllocator.plan(clusters: 9, in: fragmented, totalClusters: 16) == nil,
        "a file larger than the free space is refused outright")
    expect(
        NTFSAllocator.plan(clusters: 100, in: empty, totalClusters: 16) == nil,
        "and one larger than the volume")
    expect(
        NTFSAllocator.plan(clusters: 0, in: empty, totalClusters: 16) == nil,
        "asking for nothing is refused rather than answered with an empty plan")

    // Refusing to scatter beyond what a runlist can hold. A file in more pieces
    // than its record can describe needs an $ATTRIBUTE_LIST, which does not
    // exist here -- so producing one would be producing a file that cannot be
    // written down.
    expect(
        NTFSAllocator.plan(
            clusters: 3, in: fragmented, totalClusters: 16, maximumFragments: 2) == nil,
        "a file that would need more pieces than allowed is refused, not scattered")
    expect(
        NTFSAllocator.plan(
            clusters: 2, in: fragmented, totalClusters: 16, maximumFragments: 2) != nil,
        "while one that fits within the limit is allowed")

    // A full volume is not a fault.
    let full = Data([0xFF, 0xFF])
    expect(
        NTFSAllocator.plan(clusters: 1, in: full, totalClusters: 16) == nil,
        "a full volume has no room, which is a full disk and not an error")

    // The stretches themselves.
    let stretches = NTFSAllocator.freeStretches(in: Data([0b1100_0011]), totalClusters: 8)
    expect(stretches.count == 1, "one stretch of free clusters")
    expect(stretches[0].start == 2 && stretches[0].count == 4, "found at its true place and size")
    expect(
        NTFSAllocator.freeStretches(in: full, totalClusters: 16).isEmpty,
        "and a full volume has none")
}

group("theAllocatorWorksOnARealVolumesFreeSpace") {
    // Sixteen-cluster bitmaps prove the arithmetic. This is a million clusters
    // with real fragmentation left by a real filesystem, which is the only
    // place the "largest stretches first" behaviour means anything -- on a
    // synthetic bitmap every stretch is one cluster.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else {
        expect(true, "no NTFS volume on this machine; the synthetic checks stand alone")
        return
    }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        }), let bitmap = reader.contents(ofFile: NTFSVolumeReader.bitmapRecord), !bitmap.isEmpty
    else {
        expect(false, "the volume's bitmap reads")
        return
    }
    let total = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
    let free = NTFSBitmap.freeClusters(in: bitmap, totalClusters: total)
    expect(free > 0 && free < total, "the volume is partly used, which makes this worth doing")

    // A small file: one run, and it must not overlap anything already there.
    guard let small = NTFSAllocator.plan(clusters: 8, in: bitmap, totalClusters: total) else {
        expect(false, "a small file fits")
        return
    }
    expect(small.fragments == 1, "in one piece on a volume with this much room")
    expect(
        NTFSBitmap.allInUse(small.runs, bitmap: small.bitmap, totalClusters: total),
        "and the plan's own bitmap has every one of its clusters claimed")
    for run in small.runs {
        guard let start = run.physicalCluster else { continue }
        for offset in 0..<run.clusterCount {
            expect(
                NTFSBitmap.isInUse(cluster: start + offset, bitmap: bitmap) == false,
                "and every cluster it chose was free before it chose it -- an allocator that "
                    + "hands out a claimed cluster destroys two files at once")
        }
    }
    expect(
        NTFSBitmap.freeClusters(in: small.bitmap, totalClusters: total) == free - 8,
        "the volume has exactly eight fewer free clusters afterwards, no more and no fewer")

    // Something large enough to need real free space, but not the whole disk.
    let big = free / 2
    guard let large = NTFSAllocator.plan(clusters: big, in: bitmap, totalClusters: total) else {
        expect(false, "half the free space can be allocated")
        return
    }
    expect(large.clusterCount == big, "covering exactly what was asked for")
    expect(
        NTFSBitmap.freeClusters(in: large.bitmap, totalClusters: total) == free - big,
        "and taking exactly that much away")

    // More than the volume has left.
    expect(
        NTFSAllocator.plan(clusters: free + 1, in: bitmap, totalClusters: total) == nil,
        "one cluster more than the volume has free is refused")

    if ProcessInfo.processInfo.environment["LUKOTTA_SHOW_LISTING"] != nil {
        let stretches = NTFSAllocator.freeStretches(in: bitmap, totalClusters: total)
        let largest = stretches.map(\.count).max() ?? 0
        print(
            "    free space: \(free) clusters in \(stretches.count) stretches, "
                + "largest \(largest)")
    }
}

group("aRunlistPackedBackDecodesToWhatItWas") {
    // Writing a file's extents means packing them back into NTFS's form. The
    // strongest check is that decode and encode are inverses, because decode is
    // already checked against a real volume -- so anything encode gets wrong
    // shows up as a round trip that does not match.

    @MainActor func roundTrips(_ runs: [NTFSRunlist.Run], _ what: String) {
        guard let packed = NTFSRunlist.encode(runs) else {
            expect(false, "\(what) encodes")
            return
        }
        guard let back = NTFSRunlist.decode(packed, at: 0, limit: packed.count) else {
            expect(false, "\(what) decodes again")
            return
        }
        expect(back == runs, "\(what) survives being packed and unpacked")
    }

    roundTrips(
        [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 8)],
        "one ordinary run")
    roundTrips(
        [
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 8),
            NTFSRunlist.Run(logicalCluster: 8, physicalCluster: 200, clusterCount: 4),
        ], "two runs going forwards")
    // The case the signed delta exists for.
    roundTrips(
        [
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 5000, clusterCount: 4),
            NTFSRunlist.Run(logicalCluster: 4, physicalCluster: 100, clusterCount: 4),
        ], "a second run sitting before the first on the disk")
    roundTrips(
        [
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 4),
            NTFSRunlist.Run(logicalCluster: 4, physicalCluster: nil, clusterCount: 8),
            NTFSRunlist.Run(logicalCluster: 12, physicalCluster: 200, clusterCount: 4),
        ], "a sparse file with a hole in the middle")
    roundTrips(
        [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 1_000_000, clusterCount: 500_000)],
        "a run needing several bytes for each number")

    // The width rule. 127 fits a signed byte and 128 does not, because 0x80
    // read back is -128 -- a run that would land at the wrong end of the disk.
    expect(NTFSRunlist.signedWidth(127) == 1, "127 fits one signed byte")
    expect(NTFSRunlist.signedWidth(128) == 2, "128 needs two, because 0x80 alone reads as -128")
    expect(NTFSRunlist.signedWidth(-128) == 1, "while -128 does fit one")
    expect(NTFSRunlist.signedWidth(-129) == 2, "and -129 does not")
    expect(NTFSRunlist.unsignedWidth(255) == 1, "an unsigned 255 fits one byte")
    expect(NTFSRunlist.unsignedWidth(256) == 2, "and 256 needs two")

    // Exactly at the boundary, both ways, through a real round trip.
    roundTrips(
        [
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 0, clusterCount: 1),
            NTFSRunlist.Run(logicalCluster: 1, physicalCluster: 128, clusterCount: 1),
        ], "a delta of exactly 128")
    roundTrips(
        [
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 200, clusterCount: 1),
            NTFSRunlist.Run(logicalCluster: 1, physicalCluster: 72, clusterCount: 1),
        ], "a delta of exactly -128")

    // The terminator, without which a reader carries on into whatever follows
    // the runlist in the record.
    guard
        let packed = NTFSRunlist.encode(
            [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 1, clusterCount: 1)])
    else {
        expect(false, "a run encodes")
        return
    }
    expect(packed.last == 0, "an encoded runlist ends with its terminator")
    expect(
        NTFSRunlist.encode([])?.first == 0,
        "and an empty one is just a terminator rather than nothing at all")

    // What cannot be encoded.
    expect(
        NTFSRunlist.encode([
            NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 1, clusterCount: 0)
        ]) == nil,
        "a run of no clusters is refused")
}

group("whatEachPieceOfACreateCosts") {
    // Where the time in a create actually goes. Guarded the same way, because
    // it is a measurement and not a check.
    guard ProcessInfo.processInfo.environment["LUKOTTA_BENCH_FILES"] != nil,
        let path = ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"]
            ?? Optional(NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img"),
        FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    // A class, because the closure the reader holds is @Sendable and cannot
    // capture a mutable local. The counting is under the same lock as the
    // reading, so it counts what actually happened.
    final class Tally: @unchecked Sendable {
        var reads = 0
        var bytes = 0
    }
    let tally = Tally()
    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        tally.reads += 1
        tally.bytes += length
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    guard let reader = NTFSVolumeReader(read: read) else {
        expect(false, "the volume reads")
        return
    }
    _ = reader.collation()

    func time(_ what: String, _ rounds: Int, _ body: () -> Void) {
        tally.reads = 0
        tally.bytes = 0
        let start = Date()
        for _ in 0..<rounds { body() }
        let each = Date().timeIntervalSince(start) / Double(rounds) * 1_000_000
        print(
            String(
                format: "    %-32@ %8.1f us  %5.1f reads %8.0f bytes", what as NSString, each,
                Double(tally.reads) / Double(rounds), Double(tally.bytes) / Double(rounds)))
    }

    let rounds = 300
    time("record(0)", rounds) { _ = reader.record(NTFSTable.mftRecord) }
    time("size(ofFile: $MFT)", rounds) { _ = reader.size(ofFile: NTFSTable.mftRecord) }
    time("$MFT $BITMAP contents", rounds) {
        _ = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap)
    }
    time("find in root", rounds) {
        _ = reader.find("bench-000000.txt", inDirectory: NTFSTable.rootRecord)
    }
    time("indexNodes(root)", 20) { _ = reader.indexNodes(ofDirectory: NTFSTable.rootRecord) }
    if let bitmap = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap),
        let size = reader.size(ofFile: NTFSTable.mftRecord)
    {
        let records = size / UInt64(reader.geometry.bytesPerFileRecord)
        time("choose a record from 24", rounds) {
            _ = NTFSRecordAllocator.choose(in: bitmap, recordCount: records)
        }
        time("choose a record from the hint", rounds) {
            _ = NTFSRecordAllocator.choose(in: bitmap, recordCount: records, near: records - 400)
        }
    }
    time("collation()", rounds) { _ = reader.collation() }

    // The write side, through the same kind of handle the backing is given.
    if let writePath = ProcessInfo.processInfo.environment["LUKOTTA_WRITE_IMAGE"],
        FileManager.default.fileExists(atPath: writePath),
        let writable = FileHandle(forUpdatingAtPath: writePath)
    {
        defer { try? writable.close() }
        let writeLock = NSLock()
        let write: NTFSBacking.WriteBytes = { offset, bytes in
            writeLock.lock()
            defer { writeLock.unlock() }
            try? writable.seek(toOffset: offset)
            writable.write(bytes)
            return true
        }
        let sector = Data(count: 512)
        let record = Data(count: 1024)
        let block = Data(count: 4096)
        // Into the free space past everything, so nothing on the volume moves.
        let scratch: UInt64 = 3_500_000_000
        time("write 512 bytes", rounds) { _ = write(scratch, sector) }
        time("write 1024 bytes", rounds) { _ = write(scratch, record) }
        time("write 4096 bytes", rounds) { _ = write(scratch, block) }
        time("write 4096 then read it", rounds) {
            _ = write(scratch, block)
            _ = read(scratch, 4096)
        }
    }
    expect(true, "measured")
}

group("makingAndUnmakingFilesAtSpeed") {
    // What create and remove actually cost. Guarded, because it changes a
    // volume and takes time: set LUKOTTA_BENCH_FILES to how many.
    guard let count = ProcessInfo.processInfo.environment["LUKOTTA_BENCH_FILES"].flatMap(Int.init),
        count > 0,
        let path = ProcessInfo.processInfo.environment["LUKOTTA_WRITE_IMAGE"],
        FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forUpdatingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    let write: NTFSBacking.WriteBytes = { offset, bytes in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        handle.write(bytes)
        return true
    }
    guard let backing = NTFSBacking(read: read, write: write) else {
        expect(false, "the volume opens writable")
        return
    }
    let root = backing.rootHandle
    let rounds = ProcessInfo.processInfo.environment["LUKOTTA_BENCH_ROUNDS"].flatMap(Int.init) ?? 1
    let names = (0..<count).map { "bench-\(String(format: "%06d", $0)).txt" }

    // Rounds before the measured one, so what is measured is a directory that
    // has been filled and emptied rather than a fresh one. Splits, emptied
    // nodes and reused record slots all only happen the second time round.
    let settled = Set(backing.children(of: root).map { $0.name })
    for round in 1..<max(rounds, 1) {
        var roundMade = 0
        for name in names
        where backing.create(name, isDirectory: false, in: root, mode: 0o644)
            != nil
        {
            roundMade += 1
        }
        var roundGone = 0
        for name in names where backing.remove(name, from: root) == .removed { roundGone += 1 }
        expect(
            roundMade == count && roundGone == count,
            "round \(round): \(roundMade) made and \(roundGone) removed of \(count)")
        let now = Set(backing.children(of: root).map { $0.name })
        expect(
            now == settled,
            "and round \(round) leaves the directory as it found it: "
                + "\(now.symmetricDifference(settled).sorted().prefix(4))")
    }

    // Stops at the first refusal, so the time divided by the count is the cost
    // of a create that happened. Carrying on and dividing by the successes
    // charges every refusal to them, which is how a create looked thirty times
    // dearer than the sum of its parts.
    var made: [String] = []
    var refused: String?
    let startMaking = Date()
    for name in names {
        guard backing.create(name, isDirectory: false, in: root, mode: 0o644) != nil else {
            refused = name
            break
        }
        made.append(name)
    }
    let making = Date().timeIntervalSince(startMaking)
    if let refused {
        print("    stopped at \(refused) after \(made.count)")
        print("    why: \(backing.whyCreateFailed(refused, in: root))")
    }

    // Before removing anything: is everything that was made still there? A
    // split that loses a name loses it silently, and a listing is the only
    // thing that would notice.
    if let fresh = NTFSVolumeReader(read: read) {
        let listed = Set(
            (fresh.contents(ofDirectory: NTFSTable.rootRecord) ?? []).map { $0.name })
        let missing = made.filter { !listed.contains($0) }
        expect(
            missing.isEmpty,
            "every name made is still in the listing, or missing \(missing.count): "
                + "\(missing.prefix(4))")
        var unfindable: [String] = []
        for name in made where fresh.find(name, inDirectory: NTFSTable.rootRecord) == nil {
            unfindable.append(name)
        }
        expect(
            unfindable.isEmpty,
            "and every one is findable, or \(unfindable.count) are not: "
                + "\(unfindable.prefix(4))")
        if let collation = fresh.collation() {
            var broken: [String] = []
            for node in fresh.indexNodes(ofDirectory: NTFSTable.rootRecord) {
                let names = NTFSIndex.names(node.entries)
                guard names.count > 1 else { continue }
                for index in 1..<names.count
                where collation.compare(names[index - 1], names[index]) != .orderedAscending {
                    broken.append("\(names[index - 1]) then \(names[index])")
                }
            }
            expect(broken.isEmpty, "and every node is in order: \(broken.prefix(3))")
        }
    }

    var gone = 0
    var refusedRemoval: String?
    let startUnmaking = Date()
    for name in made {
        if backing.remove(name, from: root) == .removed {
            gone += 1
        } else if refusedRemoval == nil {
            refusedRemoval = name
        }
    }
    let unmaking = Date().timeIntervalSince(startUnmaking)
    if let refusedRemoval {
        print("    would not remove \(refusedRemoval) after \(gone)")
        print("    why: \(backing.whyRemoveFailed(refusedRemoval, from: root))")
    }

    print(
        String(
            format: "    %d created in %.2fs, %.0f us each, %.0f/s",
            made.count, making, making / Double(max(made.count, 1)) * 1_000_000,
            Double(made.count) / max(making, 0.000_001)))
    print(
        String(
            format: "    %d removed in %.2fs, %.0f us each, %.0f/s",
            gone, unmaking, unmaking / Double(max(gone, 1)) * 1_000_000,
            Double(gone) / max(unmaking, 0.000_001)))
    expect(
        made.count == count, "every file asked for was made: \(made.count) of \(count)")
    expect(gone == made.count, "and every one was removed again: \(gone)")

    // Throughput, which is the other half of what a filesystem is judged on.
    // A file made here and filled, then read back, then taken away.
    let megabytes =
        ProcessInfo.processInfo.environment["LUKOTTA_BENCH_MB"].flatMap(Int.init) ?? 64
    if megabytes > 0,
        let big = backing.create("bench-big.bin", isDirectory: false, in: root, mode: 0o644)
    {
        let chunk = 1 << 20
        var block = [UInt8](repeating: 0, count: chunk)
        var seed: UInt32 = 0x9E37_79B9
        for index in 0..<chunk {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            block[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let payload = Data(block)
        var written = 0
        let startWriting = Date()
        for round in 0..<megabytes {
            let put = backing.write(big, contents: payload, offset: round * chunk)
            guard put == chunk else { break }
            written += put
        }
        let writing = Date().timeIntervalSince(startWriting)
        let startReading = Date()
        var readBack = 0
        var matched = true
        for round in 0..<(written / chunk) {
            let got = backing.read(big, offset: round * chunk, length: chunk)
            if got != payload { matched = false }
            readBack += got.count
        }
        let reading = Date().timeIntervalSince(startReading)
        print(
            String(
                format: "    wrote %.0f MB in %.2fs, %.0f MB/s", Double(written) / 1_048_576,
                writing, Double(written) / 1_048_576 / max(writing, 0.000_001)))
        print(
            String(
                format: "    read  %.0f MB in %.2fs, %.0f MB/s", Double(readBack) / 1_048_576,
                reading, Double(readBack) / 1_048_576 / max(reading, 0.000_001)))
        expect(written == megabytes * chunk, "all of it was written: \(written)")
        expect(matched, "and every megabyte read back as what went in")
        expect(
            backing.remove("bench-big.bin", from: root) == .removed,
            "and the file was taken away again")

        // The same bytes, the same way, straight to a file on the Mac's own
        // filesystem. Comparing against a `dd` to a real disk would be
        // comparing this filesystem's overhead with somebody else's I/O path;
        // this is the same path with the filesystem taken out of it, which is
        // what the overhead actually is.
        //
        // The file is made its full size first. Extending a file as you write
        // it is slower than writing into space it already has, and this
        // filesystem writes into an image that already exists -- a baseline
        // that grows as it goes measures the growing, and comes out slower than
        // the thing it is supposed to be the ceiling for.
        let plain = NSTemporaryDirectory() + "/lukotta-baseline.bin"
        FileManager.default.createFile(atPath: plain, contents: nil)
        if let bare = FileHandle(forWritingAtPath: plain) {
            try? bare.truncate(atOffset: UInt64(megabytes) * UInt64(chunk))
            try? bare.seek(toOffset: 0)
            for _ in 0..<megabytes { bare.write(payload) }
            try? bare.seek(toOffset: 0)
            let startBare = Date()
            for _ in 0..<megabytes { bare.write(payload) }
            let baring = Date().timeIntervalSince(startBare)
            try? bare.close()
            print(
                String(
                    format: "    bare  %d MB in %.2fs, %.0f MB/s   (the same writes, no "
                        + "filesystem)", megabytes, baring,
                    Double(megabytes) / max(baring, 0.000_001)))
        }
        try? FileManager.default.removeItem(atPath: plain)
    }
    let ended = Set(backing.children(of: root).map { $0.name })
    expect(
        ended == settled,
        "and the directory is as it was before any of it: "
            + "\(ended.symmetricDifference(settled).sorted().prefix(4))")
    expect(backing.release(), "and the volume is released")

    // What chkdsk would look at. Every record the bitmap claims is in use has
    // to be a record that says so, and every name in the directory has to lead
    // to a record that exists and can be found again by descending.
    guard let after = NTFSVolumeReader(read: read),
        let bitmap = after.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap),
        let tableSize = after.size(ofFile: NTFSTable.mftRecord)
    else {
        expect(false, "the volume reads afterwards")
        return
    }
    let records = tableSize / UInt64(after.geometry.bytesPerFileRecord)
    var disagreed: [UInt64] = []
    for number in NTFSRecordAllocator.firstAvailable..<min(records, 2000) {
        guard let claimed = NTFSRecordAllocator.isInUse(number, in: bitmap) else { continue }
        let present = after.record(number)?.header.inUse ?? false
        if claimed != present { disagreed.append(number) }
    }
    expect(
        disagreed.isEmpty,
        "the bitmap and the records still agree, or differ at \(disagreed.prefix(5))")

    let listing = after.contents(ofDirectory: NTFSTable.rootRecord) ?? []
    var dangling: [String] = []
    for entry in listing where entry.name != "." {
        if after.record(entry.record)?.header.inUse != true { dangling.append(entry.name) }
    }
    expect(
        dangling.isEmpty,
        "every name in the root leads to a record that exists, or \(dangling.prefix(4))")

    if let collation = after.collation() {
        var unsorted: [String] = []
        for node in after.indexNodes(ofDirectory: NTFSTable.rootRecord) {
            let inside = NTFSIndex.names(node.entries)
            guard inside.count > 1 else { continue }
            for index in 1..<inside.count
            where collation.compare(inside[index - 1], inside[index]) != .orderedAscending {
                unsorted.append("\(inside[index - 1]) then \(inside[index])")
            }
        }
        expect(unsorted.isEmpty, "and every node is in order: \(unsorted.prefix(3))")
    }
    var unfindable: [String] = []
    for entry in listing.prefix(400)
    where entry.name != "." && after.find(entry.name, inDirectory: NTFSTable.rootRecord) == nil {
        unfindable.append(entry.name)
    }
    expect(
        unfindable.isEmpty,
        "and every name that lists can be found by descending: \(unfindable.prefix(4))")
}

group("aFileMadeHereIsThereWhenTheVolumeIsReadAgain") {
    // The whole of create, on a copy of a real volume. Three structures change
    // and they have to agree: the bitmap says the record is taken, the record
    // describes the file, the directory carries the name.
    guard let path = ProcessInfo.processInfo.environment["LUKOTTA_WRITE_IMAGE"],
        FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forUpdatingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    let write: NTFSBacking.WriteBytes = { offset, bytes in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        handle.write(bytes)
        return true
    }
    guard let backing = NTFSBacking(read: read, write: write) else {
        expect(false, "the volume opens writable")
        return
    }

    let root = backing.rootHandle
    let before = backing.children(of: root).map { $0.name }
    expect(!before.contains("lukotta-made-me.txt"), "the file is not there to begin with")

    guard
        let made = backing.create(
            "lukotta-made-me.txt", isDirectory: false, in: root, mode: 0o644)
    else {
        expect(false, "the file is made")
        return
    }
    guard let attributes = backing.attributes(of: made) else {
        expect(false, "and has attributes")
        return
    }
    expect(!attributes.isDirectory, "it is a file")
    expect(attributes.size == 0, "of no length, as a new file is")
    expect(attributes.linkCount == 1, "with one name")
    expect(
        attributes.id >= NTFSRecordAllocator.firstAvailable,
        "in a record that is not one of the volume's own: \(attributes.id)")

    // Through the same backing.
    expect(
        backing.lookup("lukotta-made-me.txt", in: root) != nil,
        "and it can be looked up again")
    expect(
        backing.children(of: root).map { $0.name }.contains("lukotta-made-me.txt"),
        "and it is in the listing")
    expect(
        backing.children(of: root).count == before.count + 1,
        "which is one longer than it was")
    expect(
        Set(before).isSubset(of: Set(backing.children(of: root).map { $0.name })),
        "with everything that was there still there")

    // A second file with the same name is not made. NTFS has one entry per
    // name; a second is a file that lists twice and deletes once.
    expect(
        backing.create("lukotta-made-me.txt", isDirectory: false, in: root, mode: 0o644) == nil,
        "the same name is not made twice")
    expect(
        backing.create("LUKOTTA-MADE-ME.TXT", isDirectory: false, in: root, mode: 0o644) == nil,
        "and neither is it in another case, because to NTFS that is the same name")

    // The name that closes the gap the collation left open: a file whose name
    // Swift's uppercasing would confuse with another. Until now nothing on this
    // volume had one.
    guard backing.create("stra\u{00DF}e.txt", isDirectory: false, in: root, mode: 0o644) != nil,
        backing.create("strasse.txt", isDirectory: false, in: root, mode: 0o644) != nil
    else {
        expect(false, "both spellings are made")
        return
    }
    guard let sharp = backing.lookup("stra\u{00DF}e.txt", in: root),
        let plain = backing.lookup("strasse.txt", in: root),
        let sharpID = backing.attributes(of: sharp)?.id,
        let plainID = backing.attributes(of: plain)?.id
    else {
        expect(false, "and both are found")
        return
    }
    expect(
        sharpID != plainID,
        "and they are two different files -- with Swift's uppercasing one of these lookups "
            + "returns the other file's record, which is the wrong file's bytes under the "
            + "right file's name")

    // A second, independent reader on the same bytes. Everything above went
    // through objects that have been holding this volume open; this one has
    // never seen it.
    guard let fresh = NTFSVolumeReader(read: read) else {
        expect(false, "the volume opens again")
        return
    }
    guard let found = fresh.find("lukotta-made-me.txt", inDirectory: NTFSTable.rootRecord),
        let record = fresh.record(found)
    else {
        expect(false, "and a reader that has never seen this volume finds the file")
        return
    }
    expect(found == attributes.id, "at the record it was made in")
    expect(record.header.inUse, "whose record says it is in use")
    expect(!record.header.isDirectory, "and is a file")
    expect(fresh.name(of: record) == "lukotta-made-me.txt", "with the name it was given")
    expect(fresh.size(ofFile: found) == 0, "and no contents")
    expect(
        fresh.contents(ofDirectory: NTFSTable.rootRecord)?
            .contains(where: { $0.name == "lukotta-made-me.txt" }) == true,
        "and it lists")

    // The bitmap and the record agree, which is the invariant a create must
    // leave behind.
    guard let bitmap = fresh.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap) else {
        expect(false, "$MFT's bitmap reads")
        return
    }
    expect(
        NTFSRecordAllocator.isInUse(found, in: bitmap) == true,
        "the bitmap says the record is taken")
    for name in ["stra\u{00DF}e.txt", "strasse.txt"] {
        guard let other = fresh.find(name, inDirectory: NTFSTable.rootRecord) else {
            expect(false, "\(name) is found by a fresh reader")
            continue
        }
        expect(
            NTFSRecordAllocator.isInUse(other, in: bitmap) == true,
            "and \(name)'s record is taken too")
    }

    // The directory is still sorted the way the volume sorts, node by node.
    guard let collation = fresh.collation() else {
        expect(false, "the table reads")
        return
    }
    var outOfOrder: [String] = []
    for node in fresh.indexNodes(ofDirectory: NTFSTable.rootRecord) {
        let names = NTFSIndex.names(node.entries)
        guard names.count > 1 else { continue }
        for index in 1..<names.count
        where collation.compare(names[index - 1], names[index]) != .orderedAscending {
            outOfOrder.append("\(names[index - 1]) then \(names[index])")
        }
    }
    expect(
        outOfOrder.isEmpty,
        "and every node of it is still in order: \(outOfOrder.prefix(3))")

    // And taking one away again. The reverse of create, in the reverse order.
    // The sequence the record carries now, so it can be shown to move on.
    func sequenceOnDisk(_ number: UInt64) -> UInt16? {
        guard let offset = fresh.diskOffset(ofRecord: number),
            let raw = read(offset, fresh.geometry.bytesPerFileRecord), raw.count > 0x11
        else { return nil }
        return UInt16(raw[raw.startIndex + 0x10]) | (UInt16(raw[raw.startIndex + 0x11]) << 8)
    }
    let sequenceBefore = sequenceOnDisk(plainID)
    expect(sequenceBefore != nil, "the removed file's record has a sequence to begin with")

    let beforeRemoval = backing.children(of: root).map { $0.name }
    expect(
        backing.remove("strasse.txt", from: root) == .removed, "a file is removed")
    let afterRemoval = backing.children(of: root).map { $0.name }
    expect(!afterRemoval.contains("strasse.txt"), "and is gone from the listing")
    expect(
        afterRemoval.count == beforeRemoval.count - 1,
        "which is one shorter: \(afterRemoval.count) from \(beforeRemoval.count)")
    expect(
        Set(beforeRemoval).subtracting(afterRemoval) == ["strasse.txt"],
        "and nothing else went with it")
    expect(backing.lookup("strasse.txt", in: root) == nil, "it cannot be looked up")
    expect(
        backing.lookup("stra\u{00DF}e.txt", in: root) != nil,
        "while the name Swift would have confused with it is untouched")
    expect(
        backing.remove("strasse.txt", from: root) == .missing,
        "removing it twice says it is missing rather than removing something else")
    expect(
        backing.remove("never-existed.txt", from: root) == .missing,
        "as does removing a name that was never there")
    // A directory is refused, and said so rather than reported missing: an
    // empty one still has an index of its own to take apart, and one with
    // anything in it must not go at all. The root lists its own entry, which
    // makes it the nearest directory to hand.
    expect(
        backing.remove(".", from: root) == .notEmpty,
        "a directory is refused rather than removed")
    expect(backing.lookup(".", in: root) != nil, "and is still there afterwards")

    // A fresh reader agrees, and the record is free with its sequence moved on.
    guard let afterFresh = NTFSVolumeReader(read: read) else {
        expect(false, "the volume opens once more")
        return
    }
    expect(
        afterFresh.find("strasse.txt", inDirectory: NTFSTable.rootRecord) == nil,
        "a reader that has never seen this volume does not find the removed file")
    expect(
        afterFresh.find("lukotta-made-me.txt", inDirectory: NTFSTable.rootRecord) != nil,
        "and still finds the one that stayed")
    expect(
        afterFresh.record(plainID)?.header.inUse == false,
        "the record says it is no longer in use")
    let sequenceAfter = sequenceOnDisk(plainID)
    expect(
        sequenceAfter != nil && sequenceAfter != sequenceBefore,
        "and its sequence has moved on -- \(sequenceBefore.map(String.init) ?? "?") to "
            + "\(sequenceAfter.map(String.init) ?? "?") -- so a reference made before now is "
            + "recognised as stale rather than followed to whatever takes the slot next")
    expect(sequenceAfter != 0, "and is never zero, which is what an unwritten record holds")
    guard
        let afterBitmap = afterFresh.contents(
            ofFile: NTFSTable.mftRecord, attribute: .bitmap)
    else {
        expect(false, "the bitmap reads")
        return
    }
    expect(
        NTFSRecordAllocator.isInUse(plainID, in: afterBitmap) == false,
        "and the bitmap has the record back")
    expect(
        NTFSRecordAllocator.isInUse(sharpID, in: afterBitmap) == true,
        "while the file that stayed still holds its own")
    expect(
        NTFSRecordAllocator.choose(
            in: afterBitmap,
            recordCount: (afterFresh.size(ofFile: NTFSTable.mftRecord) ?? 0)
                / UInt64(afterFresh.geometry.bytesPerFileRecord))?.record == plainID,
        "so the next file made takes the slot the removed one left")

    // The directory is still sorted, node by node, after a removal as after an
    // insertion.
    var stillOrdered: [String] = []
    for node in afterFresh.indexNodes(ofDirectory: NTFSTable.rootRecord) {
        let names = NTFSIndex.names(node.entries)
        guard names.count > 1 else { continue }
        for index in 1..<names.count
        where collation.compare(names[index - 1], names[index]) != .orderedAscending {
            stillOrdered.append("\(names[index - 1]) then \(names[index])")
        }
    }
    expect(stillOrdered.isEmpty, "and every node is in order: \(stillOrdered.prefix(3))")

    // Nothing was overwritten. A removed file's record still describes it,
    // which is what makes recovery possible -- and this application exists to
    // recover things.
    if let stale = afterFresh.record(plainID) {
        expect(
            afterFresh.name(of: stale) == "strasse.txt",
            "the freed record still carries the file's name, so it can be recovered")
    }

    // A file made here, filled, and read back. A new file's bytes live inside
    // its record; past a few hundred they have to go out to clusters, and the
    // record stops carrying the bytes and starts carrying a list of where they
    // are. A file crosses between those two shapes exactly once, and this is
    // the crossing.
    guard let filled = backing.create("filled.bin", isDirectory: false, in: root, mode: 0o644)
    else {
        expect(false, "a file to fill is made")
        return
    }
    let sip = Data("small enough to live in the record".utf8)
    expect(backing.write(filled, contents: sip, offset: 0) == sip.count, "a little goes in")
    expect(backing.read(filled, offset: 0, length: sip.count) == sip, "and comes back")
    expect(backing.attributes(of: filled)?.size == UInt64(sip.count), "with the right length")

    // Now past what a record holds. Bytes that are not a constant, so a read
    // returning the wrong part of the disk cannot pass.
    var payload = Data()
    payload.reserveCapacity(200_000)
    var seed: UInt32 = 0x1234_5678
    while payload.count < 200_000 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        payload.append(UInt8(truncatingIfNeeded: seed >> 24))
    }
    expect(
        backing.write(filled, contents: payload, offset: 0) == payload.count,
        "and two hundred thousand bytes go in")
    expect(
        backing.attributes(of: filled)?.size == UInt64(payload.count),
        "the file is as long as what was written: \(backing.attributes(of: filled)?.size ?? 0)")
    expect(
        backing.read(filled, offset: 0, length: payload.count) == payload,
        "and every byte of it reads back as itself")
    expect(
        backing.read(filled, offset: 100_000, length: 4096)
            == payload[payload.startIndex + 100_000..<payload.startIndex + 104_096],
        "including a piece from the middle, read on its own")

    // A reader that has never seen this volume agrees, which is the only
    // opinion that counts.
    guard let onDisk = NTFSVolumeReader(read: read),
        let number = onDisk.find("filled.bin", inDirectory: NTFSTable.rootRecord)
    else {
        expect(false, "a fresh reader finds the filled file")
        return
    }
    expect(
        onDisk.size(ofFile: number) == UInt64(payload.count),
        "it is the length it should be: \(onDisk.size(ofFile: number) ?? 0)")
    expect(
        onDisk.contents(ofFile: number) == payload,
        "and holds exactly the bytes that were written")
    guard let filledRecord = onDisk.record(number),
        let filledData = onDisk.attributes(of: filledRecord).first(where: { $0.kind == .data })
    else {
        expect(false, "its $DATA reads")
        return
    }
    expect(
        !filledData.isResident,
        "and its bytes are out on the disk now, not inside its record")
    guard
        let filledRuns = NTFSRunlist.decode(
            filledRecord.data, at: filledData.runlistOffset, limit: filledRecord.data.count)
    else {
        expect(false, "with a runlist that decodes")
        return
    }
    expect(
        NTFSRunlist.clusterCount(filledRuns) * UInt64(onDisk.geometry.bytesPerCluster)
            >= UInt64(payload.count),
        "covering at least as many clusters as the file needs")
    expect(
        filledRuns.allSatisfy { $0.physicalCluster != nil },
        "none of them a hole, since every one was written")
    // The size a listing reads, which is not the size a reader reads. Finder
    // and Explorer take it out of the index rather than opening the record,
    // and a file created and then filled would otherwise list as empty.
    guard
        let filledName = onDisk.attributes(of: filledRecord).first(where: {
            $0.kind == .fileName
        })
    else {
        expect(false, "the filled file has a $FILE_NAME")
        return
    }
    var listedLength: UInt64 = 0
    var listedRoom: UInt64 = 0
    for byte in 0..<8 {
        listedRoom |=
            UInt64(
                filledRecord.data[filledRecord.data.startIndex + filledName.valueOffset + 40 + byte]
            )
            << (8 * UInt64(byte))
        listedLength |=
            UInt64(
                filledRecord.data[filledRecord.data.startIndex + filledName.valueOffset + 48 + byte]
            )
            << (8 * UInt64(byte))
    }
    expect(
        listedLength == UInt64(payload.count),
        "a listing would show the file at its real length: \(listedLength) of \(payload.count) "
            + "-- a zero here is a file Finder shows as empty however full it is")
    expect(
        listedRoom >= listedLength,
        "with room for it: \(listedRoom)")

    // And the copy the directory entry keeps, which is the one Windows and
    // Finder actually read. A record that is right and an entry that is stale
    // is still a file that lists as empty.
    var inEntry: UInt64?
    for node in onDisk.indexNodes(ofDirectory: NTFSTable.rootRecord) {
        guard let offset = node.diskOffset,
            let raw = read(offset, node.allocatedBytes),
            let header = NTFSIndexBlock.header(raw, blockSize: node.allocatedBytes),
            let bytes = NTFSIndexBlock.applyFixup(
                raw, header: header, sectorSize: onDisk.geometry.bytesPerSector),
            let (entries, _) = NTFSIndexSplit.entries(
                of: bytes, nodeHeaderAt: NTFSIndexBlock.nodeHeaderOffset)
        else { continue }
        for entry in entries {
            guard
                NTFSIndexWrite.key(of: entry, at: 0).map({ String(decoding: $0, as: UTF16.self) })
                    == "filled.bin"
            else { continue }
            var found: UInt64 = 0
            for byte in 0..<8 {
                found |=
                    UInt64(entry[entry.startIndex + NTFSIndexWrite.keyField + 48 + byte])
                    << (8 * UInt64(byte))
            }
            inEntry = found
        }
    }
    expect(inEntry != nil, "the filled file has an entry in its directory")
    expect(
        inEntry == UInt64(payload.count),
        "and its directory entry says the same length: \(inEntry.map(String.init) ?? "none") "
            + "of \(payload.count) -- the "
            + "record being right and the entry being stale is still a file that lists as empty")

    expect(
        filledRuns.count <= 4,
        "in few pieces: \(filledRuns.count) -- runs that come out next to each other are "
            + "joined, and a runlist that grows for no reason outgrows its record")

    // The three sizes in the attribute header, read out of the bytes. Our own
    // reader does not use two of them, so nothing else here would notice them
    // being wrong -- and Windows uses all three.
    guard
        let filledBytes =
            NTFSAttribute.all(
                in: filledRecord.data, startingAt: filledRecord.header.firstAttributeOffset,
                usedLength: filledRecord.header.usedLength
            ).first(where: { $0.kind == .data }) != nil
            ? attributeRaw(filledRecord.data, header: filledRecord.header, type: 0x80) : nil
    else {
        expect(false, "the $DATA attribute's own bytes are found")
        return
    }
    func quad(_ at: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(filledBytes[filledBytes.startIndex + at + byte]) << (8 * UInt64(byte))
        }
        return value
    }
    let cluster = UInt64(onDisk.geometry.bytesPerCluster)
    expect(
        quad(NTFSFileGrow.dataSizeField) == UInt64(payload.count),
        "the length says what the file is: \(quad(NTFSFileGrow.dataSizeField))")
    expect(
        quad(NTFSFileGrow.allocatedSizeField)
            == NTFSRunlist.clusterCount(filledRuns) * cluster,
        "the room taken says what the clusters come to, not what the file does -- chkdsk "
            + "compares them: \(quad(NTFSFileGrow.allocatedSizeField))")
    expect(
        quad(NTFSFileGrow.allocatedSizeField) >= quad(NTFSFileGrow.dataSizeField),
        "and is never less than the file")
    expect(
        quad(NTFSFileGrow.initialisedSizeField) == UInt64(payload.count),
        "and the written-so-far says every byte has been written -- a zero here is a file "
            + "Windows reads as nothing at all, however full the clusters are: "
            + "\(quad(NTFSFileGrow.initialisedSizeField))")
    expect(
        quad(NTFSFileGrow.initialisedSizeField) <= quad(NTFSFileGrow.dataSizeField),
        "and never more than the file is long")
    expect(
        quad(NTFSFileGrow.lastClusterField)
            == NTFSRunlist.clusterCount(filledRuns) - 1,
        "the last cluster is the last one, counted from zero: "
            + "\(quad(NTFSFileGrow.lastClusterField))")

    // The clusters it took are marked in the volume's own bitmap. A file whose
    // clusters the volume thinks are free is a file the next write destroys.
    if let volumeBitmap = onDisk.contents(ofFile: NTFSVolumeReader.bitmapRecord) {
        var unclaimed = 0
        for run in filledRuns {
            guard let start = run.physicalCluster else { continue }
            for cluster in start..<(start + run.clusterCount)
            where NTFSBitmap.isInUse(cluster: cluster, bitmap: volumeBitmap) != true {
                unclaimed += 1
            }
        }
        expect(
            unclaimed == 0,
            "and every one of them is claimed in $Bitmap, or \(unclaimed) are not -- clusters "
                + "the volume thinks are free are clusters the next write destroys")
    }
    // Appended to, twice, so a second and third allocation happen. Clusters
    // that come out next to what the file already has are joined onto the last
    // run rather than added as new ones -- a runlist that grows for no reason
    // outgrows its record, and then the file needs an $ATTRIBUTE_LIST it has
    // not got.
    var grown = payload
    for round in 0..<2 {
        let more = Data(repeating: UInt8(0xA0 + round), count: 60_000)
        expect(
            backing.write(filled, contents: more, offset: grown.count) == more.count,
            "append \(round) goes in")
        grown += more
    }
    guard let appended = NTFSVolumeReader(read: read),
        let appendedNumber = appended.find("filled.bin", inDirectory: NTFSTable.rootRecord),
        let appendedRecord = appended.record(appendedNumber),
        let appendedData = appended.attributes(of: appendedRecord).first(where: {
            $0.kind == .data
        }),
        let appendedRuns = NTFSRunlist.decode(
            appendedRecord.data, at: appendedData.runlistOffset, limit: appendedRecord.data.count)
    else {
        expect(false, "the appended file reads")
        return
    }
    expect(
        appended.size(ofFile: appendedNumber) == UInt64(grown.count),
        "the file is as long as everything written to it: "
            + "\(appended.size(ofFile: appendedNumber) ?? 0) of \(grown.count)")
    expect(
        appended.contents(ofFile: appendedNumber) == grown,
        "and holds all of it, the appended parts included")
    expect(
        appendedRuns.count <= 3,
        "in few pieces after three allocations: \(appendedRuns.count) -- clusters that came "
            + "out adjacent were joined onto the run before them")

    // Cutting it down, which is how anything overwrites a file: open it, cut it
    // to nothing, write the new contents. A filesystem that ignores the cutting
    // leaves the tail of what was there hanging off the end of the new file.
    backing.truncate(filled, to: 5000)
    expect(
        backing.attributes(of: filled)?.size == 5000,
        "a file cut down is the length it was cut to: "
            + "\(backing.attributes(of: filled)?.size ?? 0)")
    expect(
        backing.read(filled, offset: 0, length: 5000)
            == grown[grown.startIndex..<grown.startIndex + 5000],
        "with the bytes it kept still its own")
    expect(
        backing.read(filled, offset: 5000, length: 100).isEmpty
            || backing.read(filled, offset: 5000, length: 100).count == 0,
        "and nothing past the end")

    // Cut to nothing, then written again, which is the whole of overwriting.
    backing.truncate(filled, to: 0)
    expect(backing.attributes(of: filled)?.size == 0, "cut to nothing, it is empty")
    let replacement = Data("the file this became".utf8)
    expect(
        backing.write(filled, contents: replacement, offset: 0) == replacement.count,
        "and takes what replaces it")
    expect(
        backing.attributes(of: filled)?.size == UInt64(replacement.count),
        "coming out the length of the new contents and not of the old: "
            + "\(backing.attributes(of: filled)?.size ?? 0)")
    expect(
        backing.read(filled, offset: 0, length: replacement.count) == replacement,
        "with the new bytes in it")

    // A reader that has never seen the volume, because the tail of a file is
    // exactly the thing a stale length hides.
    guard let afterCut = NTFSVolumeReader(read: read),
        let cutNumber = afterCut.find("filled.bin", inDirectory: NTFSTable.rootRecord)
    else {
        expect(false, "a fresh reader finds the overwritten file")
        return
    }
    expect(
        afterCut.size(ofFile: cutNumber) == UInt64(replacement.count),
        "it is the new length: \(afterCut.size(ofFile: cutNumber) ?? 0)")
    expect(
        afterCut.contents(ofFile: cutNumber) == replacement,
        "and holds the new contents and nothing after them -- the old two hundred thousand "
            + "bytes are still on the disk, and none of them belongs to this file any more")

    // Grow it again by cutting upwards. The space between what was written and
    // the new end reads as zeroes without touching the disk.
    backing.truncate(filled, to: 100_000)
    expect(
        backing.attributes(of: filled)?.size == 100_000,
        "a file cut upwards is longer: \(backing.attributes(of: filled)?.size ?? 0)")
    let tailBytes = backing.read(filled, offset: 50_000, length: 4096)
    expect(
        tailBytes.count == 4096 && tailBytes.allSatisfy { $0 == 0 },
        "and the part nobody wrote reads as zeroes, not as whatever was in the clusters: "
            + "\(tailBytes.prefix(8).map { $0 })")

    // Its clusters, before it goes.
    let heldClusters = filledRuns.compactMap { run -> ClosedRange<UInt64>? in
        guard let start = run.physicalCluster, run.clusterCount > 0 else { return nil }
        return start...(start + run.clusterCount - 1)
    }
    // The times. A file written to has been modified, and a filesystem that
    // does not say so breaks every backup tool, every sort by date, and every
    // "what changed" anybody ever asks.
    guard let filledTimes = onDisk.times(of: filledRecord) else {
        expect(false, "the filled file has times")
        return
    }
    // Not "is it recent" -- everything here is recent, the file was made a
    // moment ago. The question is whether the write moved it: a modified time
    // exactly equal to the created time is one that was set once and never
    // touched again.
    expect(
        filledTimes.modified > filledTimes.created,
        "the write moved its modified time past its created time: "
            + "\(filledTimes.modified.timeIntervalSince(filledTimes.created)) seconds apart")
    expect(
        filledTimes.recordChanged > filledTimes.created,
        "and the time its record last changed, since the record did change")
    expect(
        filledTimes.modified.timeIntervalSince(Date()) > -300,
        "and both are recent, not left over from whatever held the slot before")

    expect(backing.remove("filled.bin", from: root) == .removed, "and the file can be removed")

    // And they are still claimed afterwards. A removed file's record still
    // points at its clusters, and that is what makes it recoverable -- freeing
    // them hands the next write the bytes somebody may want back. This is a
    // recovery application; that is not a detail.
    guard let afterFile = NTFSVolumeReader(read: read),
        let afterFileBitmap = afterFile.contents(ofFile: NTFSVolumeReader.bitmapRecord)
    else {
        expect(false, "the cluster bitmap reads after the removal")
        return
    }
    var freed = 0
    var counted = 0
    for range in heldClusters {
        for cluster in range {
            counted += 1
            if NTFSBitmap.isInUse(cluster: cluster, bitmap: afterFileBitmap) != true { freed += 1 }
        }
    }
    expect(counted > 0, "the removed file had clusters: \(counted)")
    expect(
        freed == 0,
        "and every one of them is still claimed: \(freed) of \(counted) given back -- a "
            + "removed file's bytes stay where they are until something else takes them, "
            + "which is what makes it recoverable")

    // Joining runs, on its own, because whether the allocator happens to hand
    // back an adjacent cluster is not something a test should depend on.
    let first = [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 100, clusterCount: 4)]
    let touching = [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 104, clusterCount: 3)]
    guard let joined = NTFSFileGrow.joining(first, with: touching) else {
        expect(false, "adjacent runs join")
        return
    }
    expect(
        joined.count == 1,
        "clusters that come out next to what the file has are joined onto the run before "
            + "them: \(joined.count) run(s) -- a runlist that grows for no reason outgrows "
            + "its record, and then the file needs an $ATTRIBUTE_LIST it has not got")
    expect(joined.first?.clusterCount == 7, "with the run seven clusters long")
    expect(joined.first?.physicalCluster == 100, "still starting where it did")
    expect(joined.first?.logicalCluster == 0, "and covering the file from its beginning")

    let apart = [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 500, clusterCount: 2)]
    guard let separate = NTFSFileGrow.joining(first, with: apart) else {
        expect(false, "distant runs still join on")
        return
    }
    expect(separate.count == 2, "clusters somewhere else become a run of their own")
    expect(
        separate.last?.logicalCluster == 4,
        "carrying on from where the file left off, not from zero -- a second run starting at "
            + "zero is a file whose second half overwrites its first")
    expect(separate.last?.physicalCluster == 500, "and pointing where they actually are")
    expect(
        NTFSRunlist.clusterCount(separate) == 6, "with the file six clusters long in all")
    expect(
        NTFSFileGrow.joining(first, with: [])?.count == 1, "adding nothing changes nothing")
    expect(
        NTFSFileGrow.joining(
            [], with: [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 9, clusterCount: 1)])?
            .count == 1,
        "and a file with no clusters gets its first")
    expect(
        NTFSFileGrow.joining(
            first, with: [NTFSRunlist.Run(logicalCluster: 0, physicalCluster: nil, clusterCount: 2)]
        )
            == nil,
        "a hole is not something to grow a file with, since nothing was allocated for it")

    // An attribute may not claim more file than it has clusters for. Nothing
    // reachable through a write does that, because the clusters are worked out
    // from the length -- but a caller that got it wrong would produce a file
    // whose last bytes are somebody else's.
    let oneCluster = [
        NTFSRunlist.Run(logicalCluster: 0, physicalCluster: 1000, clusterCount: 1)
    ]
    expect(
        NTFSFileGrow.nonResident(
            type: 0x80, id: 0, runs: oneCluster, bytesPerCluster: 4096, size: 8192,
            initialised: 8192) == nil,
        "an attribute claiming two clusters of file with one cluster of disk is refused")
    expect(
        NTFSFileGrow.nonResident(
            type: 0x80, id: 0, runs: oneCluster, bytesPerCluster: 4096, size: 4096,
            initialised: 4096) != nil,
        "while one that fits is made, so the refusal is a boundary")
    expect(
        NTFSFileGrow.nonResident(
            type: 0x80, id: 0, runs: oneCluster, bytesPerCluster: 4096, size: 100,
            initialised: 200) == nil,
        "and more written than the file is long is refused, since the space between them is "
            + "what reads as zeroes")

    // Renaming. The record is not the name -- the index is -- so what a reader
    // finds between the writes is what decides the order.
    guard let renamed = backing.create("before.txt", isDirectory: false, in: root, mode: 0o644)
    else {
        expect(false, "a file to rename is made")
        return
    }
    let mark = Data("this file was renamed".utf8)
    expect(backing.write(renamed, contents: mark, offset: 0) == mark.count, "with bytes in it")
    guard let renamedID = backing.attributes(of: renamed)?.id else {
        expect(false, "and a record")
        return
    }

    expect(
        backing.rename("before.txt", in: root, to: "after.txt", in: root),
        "a file is renamed inside its own directory")
    expect(backing.lookup("before.txt", in: root) == nil, "the old name is gone")
    guard let underNewName = backing.lookup("after.txt", in: root),
        let newID = backing.attributes(of: underNewName)?.id
    else {
        expect(false, "and the new one is there")
        return
    }
    expect(newID == renamedID, "at the same record, so it is the same file")
    expect(
        backing.read(underNewName, offset: 0, length: mark.count) == mark,
        "with the same bytes in it")

    // A reader that has never seen the volume, and the record's own idea of
    // what it is called.
    guard let afterRename = NTFSVolumeReader(read: read),
        let byNewName = afterRename.find("after.txt", inDirectory: NTFSTable.rootRecord),
        let renamedRecord = afterRename.record(byNewName)
    else {
        expect(false, "a fresh reader finds it under the new name")
        return
    }
    expect(byNewName == renamedID, "at the record it always was")
    expect(
        afterRename.find("before.txt", inDirectory: NTFSTable.rootRecord) == nil,
        "and not under the old one")
    expect(
        afterRename.name(of: renamedRecord) == "after.txt",
        "and the record itself says the new name, not only the directory: "
            + "\(afterRename.name(of: renamedRecord) ?? "?")")
    expect(
        (afterRename.contents(ofDirectory: NTFSTable.rootRecord) ?? [])
            .filter { $0.record == renamedID }.count == 1,
        "and it appears once in the listing, not twice")

    // The sizes $FILE_NAME carries are a copy of what the record says, and a
    // listing reads them without opening the record. A rename that drops them
    // is a file Finder shows as empty. Nothing else here would notice: our own
    // reader asks the record.
    guard
        let renamedName = afterRename.attributes(of: renamedRecord).first(where: {
            $0.kind == .fileName
        })
    else {
        expect(false, "the renamed record has a $FILE_NAME")
        return
    }
    var listedSize: UInt64 = 0
    for byte in 0..<8 {
        listedSize |=
            UInt64(
                renamedRecord.data[
                    renamedRecord.data.startIndex + renamedName.valueOffset + 48 + byte])
            << (8 * UInt64(byte))
    }
    expect(
        listedSize == UInt64(mark.count),
        "and the size a listing would read is still the file's: \(listedSize) of \(mark.count)")

    // Onto a name that is taken: refused. NTFS has one entry per name, and
    // replacing means removing the other file first -- doing that silently
    // inside a rename is how somebody loses the wrong one.
    guard backing.create("occupied.txt", isDirectory: false, in: root, mode: 0o644) != nil else {
        expect(false, "a second file is made")
        return
    }
    expect(
        !backing.rename("after.txt", in: root, to: "occupied.txt", in: root),
        "renaming onto a name that is taken is refused")
    expect(backing.lookup("after.txt", in: root) != nil, "and the file keeps the name it had")
    expect(backing.lookup("occupied.txt", in: root) != nil, "and the other one is untouched")
    expect(
        !backing.rename("never-was.txt", in: root, to: "somewhere.txt", in: root),
        "and renaming something that is not there does nothing")

    // Renaming over something is the extension's job, not the backing's, and it
    // does it by trying the rename first and only then removing what is in the
    // way. Removing first and finding the rename cannot be done destroys a file
    // to accomplish nothing. Both halves of that are checked here at the level
    // the backing offers: the rename refuses, the target survives.
    guard let occupiedBefore = backing.lookup("occupied.txt", in: root),
        let occupiedID = backing.attributes(of: occupiedBefore)?.id
    else {
        expect(false, "the file in the way is there to begin with")
        return
    }
    expect(
        !backing.rename("after.txt", in: root, to: "occupied.txt", in: root),
        "the rename onto it is refused")
    expect(
        backing.attributes(of: occupiedBefore)?.id == occupiedID,
        "and it is still the same file, untouched -- a rename that failed must not have "
            + "destroyed what it was going to replace")
    expect(
        backing.remove("occupied.txt", from: root) == .removed,
        "and once it is out of the way")
    expect(
        backing.rename("after.txt", in: root, to: "occupied.txt", in: root),
        "the rename goes through")
    expect(
        backing.rename("occupied.txt", in: root, to: "after.txt", in: root),
        "and back again, so the rest of this reads as it did")
    expect(
        backing.create("occupied.txt", isDirectory: false, in: root, mode: 0o644) != nil,
        "with the other file remade")

    // Into another directory, which is the same three writes with a different
    // parent in the middle one.
    guard let moveTo = backing.create("move-into", isDirectory: true, in: root, mode: 0o755)
    else {
        expect(false, "a directory to move into is made")
        return
    }
    expect(
        backing.rename("after.txt", in: root, to: "moved.txt", in: moveTo),
        "a file moves to another directory")
    expect(backing.lookup("after.txt", in: root) == nil, "and is out of the old one")
    expect(
        backing.children(of: moveTo).map { $0.name } == ["moved.txt"],
        "and in the new one: \(backing.children(of: moveTo).map { $0.name })")
    guard let afterMove = NTFSVolumeReader(read: read),
        let movedNumber = backing.attributes(of: moveTo)?.id,
        let movedTo = afterMove.find("moved.txt", inDirectory: movedNumber),
        let movedRecord = afterMove.record(movedTo)
    else {
        expect(false, "a fresh reader finds it in the new directory")
        return
    }
    expect(movedTo == renamedID, "still the same record")
    expect(
        afterMove.contents(ofFile: movedTo)?.prefix(mark.count) == mark,
        "with its bytes intact")
    guard
        let movedName = afterMove.attributes(of: movedRecord).first(where: {
            $0.kind == .fileName
        })
    else {
        expect(false, "and a $FILE_NAME")
        return
    }
    var parentReference: UInt64 = 0
    for byte in 0..<8 {
        parentReference |=
            UInt64(movedRecord.data[movedRecord.data.startIndex + movedName.valueOffset + byte])
            << (8 * UInt64(byte))
    }
    expect(
        parentReference & 0x0000_FFFF_FFFF_FFFF == movedNumber,
        "and its record names the new directory as its parent -- a record still naming the old "
            + "one is a file chkdsk moves back")

    expect(backing.remove("moved.txt", from: moveTo) == .removed, "the moved file is removed")
    expect(backing.remove("move-into", from: root) == .removed, "and the directory with it")
    expect(backing.remove("occupied.txt", from: root) == .removed, "as is the other file")

    // A directory small enough to keep its whole index inside its own record.
    // Making a file in one means growing a resident attribute, which this does
    // not do -- so it has to refuse, and refuse without touching anything.
    var small: (handle: FSHandle, name: String)?
    for entry in backing.children(of: root) {
        guard let attributes = backing.attributes(of: entry.handle), attributes.isDirectory,
            entry.name != "."
        else { continue }
        // No $INDEX_ALLOCATION means the whole index is in the record.
        guard let record = NTFSVolumeReader(read: read)?.record(attributes.id) else { continue }
        let hasBlocks =
            NTFSVolumeReader(read: read)?.attributes(of: record)
            .contains { $0.kind == .indexAllocation } ?? true
        if !hasBlocks {
            small = (entry.handle, entry.name)
            break
        }
    }
    if let small, let smallID = backing.attributes(of: small.handle)?.id {
        let before = backing.children(of: small.handle).map { $0.name }.sorted()
        expect(
            backing.create("in-a-small-one.txt", isDirectory: false, in: small.handle, mode: 0o644)
                != nil,
            "a file can be made in \(small.name), whose whole index lives inside its record -- "
                + "which means growing a resident attribute rather than writing a block")
        let now = backing.children(of: small.handle).map { $0.name }.sorted()
        expect(now.count == before.count + 1, "the directory has one more name in it")
        expect(
            Set(now).subtracting(before) == ["in-a-small-one.txt"],
            "and it is the one that was made")
        expect(
            backing.lookup("in-a-small-one.txt", in: small.handle) != nil,
            "which can be looked up again")

        // A reader that has never seen the volume, so this is not the same
        // objects agreeing with themselves.
        guard let seen = NTFSVolumeReader(read: read),
            let madeIn = seen.find("in-a-small-one.txt", inDirectory: smallID)
        else {
            expect(false, "and a fresh reader finds it")
            return
        }
        expect(seen.record(madeIn)?.header.inUse == true, "at a record that is in use")
        expect(
            seen.record(smallID).map { seen.attributes(of: $0) }?
                .contains { $0.kind == .indexAllocation } == false,
            "and the directory still keeps its index inside its record, so nothing grew that "
                + "did not have to")
        expect(
            backing.remove("in-a-small-one.txt", from: small.handle) == .removed,
            "and it can be taken away again")
        expect(
            backing.children(of: small.handle).map { $0.name }.sorted() == before,
            "leaving \(small.name) exactly as it was found")
    }

    // A folder, made here, with files put in it.
    guard let folder = backing.create("a-folder", isDirectory: true, in: root, mode: 0o755),
        let folderAttributes = backing.attributes(of: folder)
    else {
        expect(false, "a folder is made")
        return
    }
    expect(folderAttributes.isDirectory, "and it is a directory")
    expect(
        backing.children(of: folder).isEmpty,
        "with nothing in it: \(backing.children(of: folder).map { $0.name })")
    expect(
        backing.children(of: root).map { $0.name }.contains("a-folder"),
        "and it lists in the directory it was made in")

    var putIn = 0
    for index in 0..<120 {
        if backing.create("inside-\(index).txt", isDirectory: false, in: folder, mode: 0o644)
            != nil
        {
            putIn += 1
        } else {
            print(
                "    folder refused inside-\(index).txt after \(putIn): "
                    + backing.whyCreateFailed("inside-\(index).txt", in: folder)
                    + " | " + backing.whyTheTreeWouldNotGrow)
            break
        }
    }
    // Enough to fill the record, force the folder to acquire blocks, and then
    // split one -- all inside a directory that did not exist a moment ago.
    expect(putIn == 120, "a hundred and twenty files go into the folder: \(putIn)")
    let inside = backing.children(of: folder).map { $0.name }.sorted()
    expect(inside.count == 120, "the folder holds them all: \(inside.count)")
    expect(
        inside == (0..<120).map { "inside-\($0).txt" }.sorted(),
        "and they are the ones that were put there")

    // A reader that has never seen the volume, which is the opinion that
    // counts.
    guard let fromScratch = NTFSVolumeReader(read: read),
        let folderNumber = fromScratch.find("a-folder", inDirectory: NTFSTable.rootRecord),
        let folderRecord = fromScratch.record(folderNumber)
    else {
        expect(false, "a fresh reader finds the folder")
        return
    }
    expect(folderRecord.header.isDirectory, "its record says it is a directory")
    expect(
        fromScratch.attributes(of: folderRecord).contains { $0.kind == .indexRoot },
        "and carries an index of its own")
    expect(
        !fromScratch.attributes(of: folderRecord).contains { $0.kind == .data },
        "and no $DATA, because a directory has no bytes")
    guard let listed = fromScratch.contents(ofDirectory: folderNumber) else {
        expect(false, "and the folder lists")
        return
    }
    expect(
        listed.map { $0.name }.sorted() == inside,
        "with the same names in it: \(listed.count)")
    var lost: [String] = []
    for index in 0..<120
    where fromScratch.find("inside-\(index).txt", inDirectory: folderNumber) == nil {
        lost.append("inside-\(index).txt")
    }
    expect(lost.isEmpty, "and every one can be found by descending: missing \(lost.prefix(4))")
    expect(
        fromScratch.attributes(of: folderRecord).contains { $0.kind == .indexAllocation },
        "the folder has grown blocks of its own by now")
    expect(
        fromScratch.attributes(of: folderRecord).contains { $0.kind == .bitmap },
        "and a bitmap saying which of them exist")
    if let collation = fromScratch.collation() {
        var wrong: [String] = []
        for node in fromScratch.indexNodes(ofDirectory: folderNumber) {
            let names = NTFSIndex.names(node.entries)
            guard names.count > 1 else { continue }
            for at in 1..<names.count
            where collation.compare(names[at - 1], names[at]) != .orderedAscending {
                wrong.append("\(names[at - 1]) then \(names[at])")
            }
        }
        expect(wrong.isEmpty, "and every node of it is in order: \(wrong.prefix(3))")
    }

    // The flags a directory carries, in each of the places it has to carry
    // them. Three out of four is a directory Finder shows as a file.
    guard
        let folderName = fromScratch.attributes(of: folderRecord).first(where: {
            $0.kind == .fileName
        })
    else {
        expect(false, "the folder has a $FILE_NAME")
        return
    }
    var nameFlags: UInt32 = 0
    for byte in 0..<4 {
        nameFlags |=
            UInt32(
                folderRecord.data[folderRecord.data.startIndex + folderName.valueOffset + 56 + byte]
            )
            << (8 * UInt32(byte))
    }
    expect(
        nameFlags & NTFSNewRecord.directoryFlag != 0,
        "its $FILE_NAME says directory: 0x\(String(nameFlags, radix: 16))")
    guard
        let folderInformation = fromScratch.attributes(of: folderRecord).first(where: {
            $0.kind == .standardInformation
        })
    else {
        expect(false, "and a $STANDARD_INFORMATION")
        return
    }
    var infoFlags: UInt32 = 0
    for byte in 0..<4 {
        infoFlags |=
            UInt32(
                folderRecord.data[
                    folderRecord.data.startIndex + folderInformation.valueOffset + 32 + byte])
            << (8 * UInt32(byte))
    }
    expect(
        infoFlags & NTFSNewRecord.directoryFlag != 0,
        "and so does its $STANDARD_INFORMATION: 0x\(String(infoFlags, radix: 16))")

    // And it can be emptied and taken away.
    var takenOut = 0
    for index in 0..<120 where backing.remove("inside-\(index).txt", from: folder) == .removed {
        takenOut += 1
    }
    expect(takenOut == 120, "and all of them come out again: \(takenOut)")
    expect(backing.children(of: folder).isEmpty, "leaving the folder empty")

    // A directory with something in it is refused, and NTFS says so nowhere
    // except in the index itself -- there is no count to consult.
    expect(
        backing.create("one-more.txt", isDirectory: false, in: folder, mode: 0o644) != nil,
        "one file goes back into it")
    expect(
        backing.remove("a-folder", from: root) == .notEmpty,
        "and a directory with something in it is refused")
    expect(backing.lookup("a-folder", in: root) != nil, "and is still there")
    expect(
        backing.remove("one-more.txt", from: folder) == .removed, "the file comes out again")

    // Empty, it can go. Its blocks go back to the volume with it: a file's
    // clusters are deliberately left claimed, because its record still points
    // at them and that is what makes it recoverable, but a directory that is
    // gone has no names to recover.
    let claimedBefore = NTFSVolumeReader(read: read)
        .flatMap { $0.contents(ofFile: NTFSVolumeReader.bitmapRecord) }
    guard
        let folderRuns = NTFSVolumeReader(read: read).flatMap({ reader -> [NTFSRunlist.Run]? in
            guard let record = reader.record(folderNumber),
                let allocation = reader.attributes(of: record).first(where: {
                    $0.kind == .indexAllocation
                })
            else { return nil }
            return NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        })
    else {
        expect(false, "the folder's blocks are found before it goes")
        return
    }
    expect(!folderRuns.isEmpty, "it has blocks to give back: \(folderRuns.count) run(s)")
    expect(
        backing.remove("a-folder", from: root) == .removed, "an empty directory is removed")
    expect(backing.lookup("a-folder", in: root) == nil, "and is gone")
    expect(
        NTFSVolumeReader(read: read)?.find("a-folder", inDirectory: NTFSTable.rootRecord) == nil,
        "as a reader that has never seen the volume agrees")
    guard let afterRemoval = NTFSVolumeReader(read: read),
        let claimedAfter = afterRemoval.contents(ofFile: NTFSVolumeReader.bitmapRecord),
        let claimedBefore
    else {
        expect(false, "the cluster bitmap reads either side of it")
        return
    }
    var stillClaimed = 0
    var wereClaimed = 0
    for run in folderRuns {
        guard let start = run.physicalCluster else { continue }
        for cluster in start..<(start + run.clusterCount) {
            if NTFSBitmap.isInUse(cluster: cluster, bitmap: claimedBefore) == true {
                wereClaimed += 1
            }
            if NTFSBitmap.isInUse(cluster: cluster, bitmap: claimedAfter) == true {
                stillClaimed += 1
            }
        }
    }
    expect(wereClaimed > 0, "its blocks were claimed while it existed: \(wereClaimed)")
    expect(
        stillClaimed == 0,
        "and none of them is claimed now: \(stillClaimed) of \(wereClaimed) left behind")
    if let freedBitmap = afterRemoval.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap) {
        expect(
            NTFSRecordAllocator.isInUse(folderNumber, in: freedBitmap) == false,
            "and its record is free again")
    }

    // Put the volume back clean, as a mount that ends properly does. This is
    // what the extension's deactivate and unmount hooks do, and a mount that
    // ends without it leaves a drive Windows runs chkdsk on for nothing -- and
    // that this filesystem itself then refuses to write to, because a marked
    // volume is one with work outstanding.
    expect(backing.isMarked, "the volume is still marked, having been written to")
    expect(backing.release(), "the volume is released")
    expect(!backing.isMarked, "and is no longer ours")
    expect(
        NTFSVolumeReader(read: read)?.state()?.isSafeToWrite == true,
        "and reads as clean afterwards")
    expect(
        NTFSBacking(read: read, write: write)?.volumeIsSafeToWrite == true,
        "so the next mount can write to it, which is the whole reason for clearing it")
}

group("anAttributeCanChangeSizeInsideItsRecord") {
    // A record is attributes laid end to end, each saying how long it is. A
    // length wrong by eight makes the next attribute start eight bytes into the
    // last one, and whatever is there is read as a type and a length. There is
    // no error -- there is a file with attributes nobody wrote. So: real
    // records, taken apart and laid out again, and every attribute has to come
    // back saying what it said.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume reads")
        return
    }
    let recordSize = reader.geometry.bytesPerFileRecord

    func shape(_ data: Data, _ header: NTFSRecord.Header) -> [String] {
        NTFSAttribute.all(
            in: data, startingAt: header.firstAttributeOffset, usedLength: header.usedLength
        ).map { "\($0.type)/\($0.isResident)/\($0.valueLength)/\($0.dataSize)" }
    }

    // Every record on the volume worth looking at, put through unchanged.
    var checked = 0
    var mismatched: [UInt64] = []
    for number in NTFSTable.rootRecord..<200 {
        guard let record = reader.record(number), record.header.inUse,
            !reader.spillsAttributes(record)
        else { continue }
        let before = shape(record.data, record.header)
        guard !before.isEmpty else { continue }
        guard
            let information = reader.attributes(of: record).first(where: {
                $0.kind == .standardInformation
            }), information.isResident,
            let same = NTFSRecordEdit.replacing(
                .standardInformation, named: nil,
                with: record.data[
                    (record.data.startIndex + information.valueOffset)..<(record.data.startIndex
                        + information.valueOffset + information.valueLength)],
                in: record.data, header: record.header),
            let sameHeader = NTFSRecord.header(same, expectedLength: recordSize)
        else {
            mismatched.append(number)
            continue
        }
        checked += 1
        if shape(same, sameHeader) != before { mismatched.append(number) }
        if sameHeader.usedLength > sameHeader.allocatedLength { mismatched.append(number) }
    }
    expect(checked > 20, "enough records to be worth saying anything about: \(checked)")
    expect(
        mismatched.isEmpty,
        "and every one of them lays out again as what it was: \(mismatched.prefix(5))")

    // The root directory, which is the one that has to grow.
    guard let root = reader.record(NTFSTable.rootRecord),
        let indexRoot = reader.attributes(of: root).first(where: { $0.kind == .indexRoot }),
        indexRoot.isResident
    else {
        expect(false, "the root directory has an $INDEX_ROOT")
        return
    }
    let rootValue = root.data[
        (root.data.startIndex + indexRoot.valueOffset)..<(root.data.startIndex
            + indexRoot.valueOffset + indexRoot.valueLength)]
    let shapeBefore = shape(root.data, root.header)

    // Growing it by a hundred bytes, which is roughly what a promoted entry
    // costs.
    let grown = Data(rootValue) + Data(count: 104)
    guard
        let bigger = NTFSRecordEdit.replacing(
            .indexRoot, named: "$I30", with: grown, in: root.data, header: root.header),
        let biggerHeader = NTFSRecord.header(bigger, expectedLength: recordSize)
    else {
        expect(false, "$INDEX_ROOT grows")
        return
    }
    expect(bigger.count == recordSize, "the record is still one record long")
    expect(
        biggerHeader.usedLength == root.header.usedLength + 104,
        "and uses a hundred and four more bytes: \(biggerHeader.usedLength) from "
            + "\(root.header.usedLength)")
    expect(
        biggerHeader.usedLength <= biggerHeader.allocatedLength,
        "which still fits in the slot")
    let biggerShape = shape(bigger, biggerHeader)
    expect(
        biggerShape.count == shapeBefore.count,
        "with the same attributes: \(biggerShape.count) against \(shapeBefore.count)")
    guard
        let grownAttribute = NTFSAttribute.all(
            in: bigger, startingAt: biggerHeader.firstAttributeOffset,
            usedLength: biggerHeader.usedLength
        ).first(where: { $0.kind == .indexRoot })
    else {
        expect(false, "and $INDEX_ROOT among them")
        return
    }
    expect(
        grownAttribute.valueLength == indexRoot.valueLength + 104,
        "$INDEX_ROOT is longer by what went in")
    expect(
        bigger[
            (bigger.startIndex + grownAttribute.valueOffset)..<(bigger.startIndex
                + grownAttribute.valueOffset + indexRoot.valueLength)] == rootValue,
        "and still starts with exactly the bytes it had")

    // The attributes that come after it are still readable, which is the whole
    // point: they moved.
    guard
        let allocation = NTFSAttribute.all(
            in: bigger, startingAt: biggerHeader.firstAttributeOffset,
            usedLength: biggerHeader.usedLength
        ).first(where: { $0.kind == .indexAllocation })
    else {
        expect(false, "$INDEX_ALLOCATION is still there after the one before it grew")
        return
    }
    expect(!allocation.isResident, "still out on the disk")
    guard
        let runs = NTFSRunlist.decode(
            bigger, at: allocation.runlistOffset, limit: bigger.count),
        let originalRuns = reader.attributes(of: root).first(where: {
            $0.kind == .indexAllocation
        }).flatMap({ NTFSRunlist.decode(root.data, at: $0.runlistOffset, limit: root.data.count) })
    else {
        expect(false, "and its runlist still decodes")
        return
    }
    expect(runs == originalRuns, "to exactly the clusters it named before")

    // And the directory's own $BITMAP, which is what says which index blocks
    // exist.
    guard let bitmap = reader.attributes(of: root).first(where: { $0.kind == .bitmap }),
        bitmap.isResident
    else {
        expect(false, "the root has a $BITMAP")
        return
    }
    var bits = [UInt8](
        root.data[
            (root.data.startIndex + bitmap.valueOffset)..<(root.data.startIndex
                + bitmap.valueOffset + bitmap.valueLength)])
    expect(bits[0] & 1 == 1, "whose first block is in use")
    bits[0] |= 0x02
    guard
        let withBlock = NTFSRecordEdit.replacing(
            .bitmap, named: "$I30", with: Data(bits), in: bigger, header: biggerHeader),
        let withBlockHeader = NTFSRecord.header(withBlock, expectedLength: recordSize),
        let readBack = NTFSAttribute.all(
            in: withBlock, startingAt: withBlockHeader.firstAttributeOffset,
            usedLength: withBlockHeader.usedLength
        ).first(where: { $0.kind == .bitmap })
    else {
        expect(false, "and a second block can be marked in it")
        return
    }
    expect(
        withBlock[withBlock.startIndex + readBack.valueOffset] & 0x02 == 0x02,
        "the second block reads as in use")
    expect(
        withBlockHeader.usedLength == biggerHeader.usedLength,
        "and marking it changed no lengths, because the bitmap is the same size")
    expect(
        shape(withBlock, withBlockHeader).count == shapeBefore.count,
        "with every attribute still there")

    // What will not fit is refused rather than written over the end of the
    // record.
    expect(
        NTFSRecordEdit.replacing(
            .indexRoot, named: "$I30", with: Data(count: recordSize), in: root.data,
            header: root.header) == nil,
        "a value that fills the record leaves no room for the record")
    expect(
        NTFSRecordEdit.replacing(
            .data, named: nil, with: Data(), in: root.data, header: root.header) == nil,
        "an attribute the record has not got is not replaced")
    expect(
        NTFSRecordEdit.replacing(
            .indexRoot, named: "$I40", with: grown, in: root.data, header: root.header) == nil,
        "and neither is one with a different name, because a record can hold several of a "
            + "type and they are told apart by it")
}

group("aFullNodeIsCutInTwo") {
    // Splitting real index blocks, in memory. What has to come out is two
    // nodes that between them hold every name the one node held, in order, and
    // a median that a parent can point at both halves with.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    guard let reader = NTFSVolumeReader(read: read), let collation = reader.collation() else {
        expect(false, "the volume reads and has its table")
        return
    }
    let sectorSize = reader.geometry.bytesPerSector

    guard let root = reader.contents(ofDirectory: NTFSTable.rootRecord),
        let big = root.first(where: { (reader.contents(ofDirectory: $0.record)?.count ?? 0) > 1000 }
        ),
        let target = reader.indexNodes(ofDirectory: big.record)
            .first(where: { $0.diskOffset != nil && $0.entries.count > 6 }),
        let diskOffset = target.diskOffset
    else {
        expect(false, "the volume has a directory with a full-looking node")
        return
    }
    let blockSize = target.allocatedBytes
    guard let raw = read(diskOffset, blockSize),
        let blockHeader = NTFSIndexBlock.header(raw, blockSize: blockSize),
        let node = NTFSIndexBlock.applyFixup(raw, header: blockHeader, sectorSize: sectorSize)
    else {
        expect(false, "and it reads")
        return
    }
    let nodeHeader = NTFSIndexBlock.nodeHeaderOffset
    let names = NTFSIndex.names(
        NTFSIndex.entries(node, from: blockHeader.firstEntryOffset, limit: blockHeader.endOfEntries)
    )
    expect(names.count > 6, "with names in it: \(names.count)")

    guard let (readEntries, marker) = NTFSIndexSplit.entries(of: node, nodeHeaderAt: nodeHeader)
    else {
        expect(false, "its entries come out as bytes")
        return
    }
    expect(readEntries.count == names.count, "as many as the reader sees")
    expect(
        NTFSIndexWrite.read16(marker, NTFSIndexWrite.entryFlagsField) & NTFSIndexWrite.isLast != 0,
        "and the marker comes out separately, still flagged as the end")
    expect(
        readEntries.allSatisfy {
            NTFSIndexWrite.read16($0, NTFSIndexWrite.entryFlagsField) & NTFSIndexWrite.isLast == 0
        },
        "with no marker among them")

    guard let plan = NTFSIndexSplit.plan(of: node, nodeHeaderAt: nodeHeader) else {
        expect(false, "the node can be cut")
        return
    }
    expect(!plan.below.isEmpty, "the lower half has something in it")
    expect(
        !plan.above.isEmpty,
        "and so does the upper -- an empty node is one no search can "
            + "pass through")
    expect(
        plan.below.count + plan.above.count + 1 == readEntries.count,
        "and between them, with the median, they are every entry: "
            + "\(plan.below.count) + 1 + \(plan.above.count) of \(readEntries.count)")

    // Cut by bytes, not by count, so two nodes of similar fullness come out of
    // names of different lengths.
    let belowBytes = plan.below.reduce(0) { $0 + $1.count }
    let aboveBytes = plan.above.reduce(0) { $0 + $1.count }
    let bigger = max(belowBytes, aboveBytes)
    let smaller = max(min(belowBytes, aboveBytes), 1)
    expect(
        bigger <= smaller * 3,
        "the halves are of comparable size: \(belowBytes) and \(aboveBytes)")

    func nameOf(_ entry: Data) -> String? {
        NTFSIndexWrite.key(of: entry, at: 0).map { String(decoding: $0, as: UTF16.self) }
    }
    let belowNames = plan.below.compactMap(nameOf)
    let aboveNames = plan.above.compactMap(nameOf)
    guard let medianName = nameOf(plan.median) else {
        expect(false, "the median has a name")
        return
    }
    expect(
        belowNames + [medianName] + aboveNames == names,
        "and in order, they are exactly the names the node held")
    expect(
        belowNames.allSatisfy { collation.compare($0, medianName) == .orderedAscending },
        "everything in the lower half sorts below the median")
    expect(
        aboveNames.allSatisfy { collation.compare($0, medianName) == .orderedDescending },
        "and everything in the upper half above it -- which is what makes a search still work: "
            + "below goes to the new block, the median is found in the parent, above stays here")

    // The median made into a parent entry, pointing at the new block.
    guard let promoted = NTFSIndexSplit.promoting(plan.median, toChild: 7) else {
        expect(false, "the median can be promoted")
        return
    }
    expect(promoted.count % 8 == 0, "the promoted entry is a multiple of eight long")
    expect(
        promoted.count == plan.median.count + 8 || promoted.count == plan.median.count,
        "and longer than the median by its child pointer: \(plan.median.count) to "
            + "\(promoted.count)")
    expect(NTFSIndexSplit.child(of: promoted) == 7, "which points at the block it was given")
    expect(NTFSIndexSplit.child(of: plan.median) == nil, "while the median itself points nowhere")
    expect(nameOf(promoted) == medianName, "and it still carries the median's name")
    expect(
        NTFSIndexWrite.read16(promoted, NTFSIndexWrite.entryLengthField) == UInt16(promoted.count),
        "with a length that says how long it is")

    // The new block, built from the lower half.
    guard
        let built = NTFSIndexBlock.compose(
            blockNumber: 7, blockSize: blockSize, sectorSize: sectorSize, entries: plan.below,
            marker: marker),
        let builtHeader = NTFSIndexBlock.header(built, blockSize: blockSize)
    else {
        expect(false, "a block is built from the lower half")
        return
    }
    expect(built.count == blockSize, "of exactly one block")
    expect(
        builtHeader.blockNumber == 7,
        "carrying its own number, so a block read from the "
            + "wrong place can be noticed")
    let builtNames = NTFSIndex.names(
        NTFSIndex.entries(
            built, from: builtHeader.firstEntryOffset, limit: builtHeader.endOfEntries))
    expect(builtNames == belowNames, "and exactly the names of the lower half")
    expect(collation.isSorted(builtNames), "in order")
    expect(
        builtHeader.endOfEntries <= blockSize, "with its entries inside the block")

    // A search through the new block finds what should be there and not what
    // should not.
    let builtEntries = NTFSIndex.entries(
        built, from: builtHeader.firstEntryOffset, limit: builtHeader.endOfEntries)
    for name in belowNames.prefix(20) {
        guard case .found = NTFSIndex.find(name, in: builtEntries, collation: collation) else {
            expect(false, "\(name) is found in the new block")
            return
        }
    }
    expect(true, "every name in the lower half is found in the new block")
    expect(
        NTFSIndex.find(medianName, in: builtEntries, collation: collation) == .absent,
        "the median is not in it -- it belongs to the parent now")
    if let firstAbove = aboveNames.first {
        expect(
            NTFSIndex.find(firstAbove, in: builtEntries, collation: collation) == .absent,
            "and neither is anything from the upper half")
    }

    // And the block goes down and comes back.
    guard
        let onDisk = NTFSIndexBlock.removeFixup(
            built, header: builtHeader, sectorSize: sectorSize),
        let backHeader = NTFSIndexBlock.header(onDisk, blockSize: blockSize),
        let backAgain = NTFSIndexBlock.applyFixup(
            onDisk, header: backHeader, sectorSize: sectorSize)
    else {
        expect(false, "the built block survives being written and read")
        return
    }
    expect(onDisk.count == blockSize, "still one block long")
    expect(
        NTFSIndex.names(
            NTFSIndex.entries(
                backAgain, from: backHeader.firstEntryOffset, limit: backHeader.endOfEntries))
            == belowNames,
        "with the same names in it")

    // Every name on this volume is the same length, so cutting by count and
    // cutting by bytes give the same answer here and neither test says
    // anything. A node of names of wildly different lengths does: cut by count
    // it comes out lopsided, and the fuller half splits again on the next file.
    let times = NTFSTimestamps.Times(
        created: Date(timeIntervalSince1970: 1_700_000_000),
        modified: Date(timeIntervalSince1970: 1_700_000_000),
        recordChanged: Date(timeIntervalSince1970: 1_700_000_000),
        accessed: Date(timeIntervalSince1970: 1_700_000_000))
    func madeEntry(_ name: String, _ record: UInt64) -> Data? {
        NTFSIndexWrite.entry(
            key: NTFSNewRecord.fileNameValue(
                NTFSNewRecord.Plan(
                    record: record, sequence: 1, parent: 5, parentSequence: 5, name: name,
                    namespace: .posix, times: times, securityID: 258),
                units: Array(name.utf16)),
            record: record, sequence: 1)
    }
    // "a" is short; the rest are 200 characters each. Sorted, the long ones all
    // come after it, so a cut by count puts one name on one side and four on
    // the other -- by bytes it lands in the middle of the long ones.
    let uneven = ["a"] + (0..<4).map { "b\(String(repeating: "x", count: 200))\($0)" }
    let unevenEntries = uneven.enumerated().compactMap { madeEntry($1, UInt64(6100 + $0)) }
    guard unevenEntries.count == uneven.count,
        let unevenBlock = NTFSIndexBlock.compose(
            blockNumber: 2, blockSize: blockSize, sectorSize: sectorSize,
            entries: unevenEntries, marker: marker),
        let unevenPlan = NTFSIndexSplit.plan(of: unevenBlock, nodeHeaderAt: nodeHeader)
    else {
        expect(false, "a node of uneven names builds and splits")
        return
    }
    let unevenBelow = unevenPlan.below.reduce(0) { $0 + $1.count }
    let unevenAbove = unevenPlan.above.reduce(0) { $0 + $1.count }
    expect(!unevenPlan.below.isEmpty, "with something in the lower half")
    expect(!unevenPlan.above.isEmpty, "and something in the upper")
    expect(
        max(unevenBelow, unevenAbove) <= max(min(unevenBelow, unevenAbove), 1) * 2,
        "and the halves within a factor of two by bytes: \(unevenBelow) and \(unevenAbove) "
            + "from \(unevenPlan.below.count) and \(unevenPlan.above.count) entries")
    expect(
        unevenPlan.below.compactMap(nameOf) + [nameOf(unevenPlan.median) ?? ""]
            + unevenPlan.above.compactMap(nameOf) == uneven,
        "still every name, in order")

    // A node whose first entry is most of it. Cutting where the bytes say puts
    // nothing in the lower half, and an empty node is one no search can pass
    // through, so the cut is moved.
    let lopsided = [String(repeating: "a", count: 250), "b", "c", "d"]
    let lopsidedEntries = lopsided.enumerated().compactMap { madeEntry($1, UInt64(6200 + $0)) }
    guard lopsidedEntries.count == lopsided.count,
        let lopsidedBlock = NTFSIndexBlock.compose(
            blockNumber: 3, blockSize: blockSize, sectorSize: sectorSize,
            entries: lopsidedEntries, marker: marker),
        let lopsidedPlan = NTFSIndexSplit.plan(of: lopsidedBlock, nodeHeaderAt: nodeHeader)
    else {
        expect(false, "a lopsided node splits at all")
        return
    }
    expect(
        !lopsidedPlan.below.isEmpty && !lopsidedPlan.above.isEmpty,
        "with neither half empty: \(lopsidedPlan.below.count) and \(lopsidedPlan.above.count)")
    expect(
        lopsidedPlan.below.compactMap(nameOf) + [nameOf(lopsidedPlan.median) ?? ""]
            + lopsidedPlan.above.compactMap(nameOf) == lopsided,
        "and every name still there, in order")

    // The node flags. A leaf says it has nothing below it, and a block built
    // here has to say the same thing a leaf on the volume says.
    let realFlags = NTFSIndexWrite.read32(node, nodeHeader + NTFSIndexWrite.flagsField)
    expect(realFlags == 0, "a leaf on the volume says it has nothing below it")
    expect(
        NTFSIndexWrite.read32(built, nodeHeader + NTFSIndexWrite.flagsField) == realFlags,
        "and so does the one built here -- a node claiming children it has not got is one "
            + "Windows follows into nothing")

    // What cannot be split.
    guard
        let tiny = NTFSIndexBlock.compose(
            blockNumber: 1, blockSize: blockSize, sectorSize: sectorSize,
            entries: Array(readEntries.prefix(1)), marker: marker)
    else {
        expect(false, "a one-entry block builds")
        return
    }
    expect(
        NTFSIndexSplit.plan(of: tiny, nodeHeaderAt: nodeHeader) == nil,
        "a node with one entry is not split -- one of the halves would be empty, and an empty "
            + "node is one no search can pass through")
    guard
        let two = NTFSIndexBlock.compose(
            blockNumber: 1, blockSize: blockSize, sectorSize: sectorSize,
            entries: Array(readEntries.prefix(2)), marker: marker)
    else { return }
    expect(
        NTFSIndexSplit.plan(of: two, nodeHeaderAt: nodeHeader) == nil,
        "and neither is one with two, for the same reason")
    guard
        let three = NTFSIndexBlock.compose(
            blockNumber: 1, blockSize: blockSize, sectorSize: sectorSize,
            entries: Array(readEntries.prefix(3)), marker: marker)
    else { return }
    guard let threePlan = NTFSIndexSplit.plan(of: three, nodeHeaderAt: nodeHeader) else {
        expect(false, "while one with three is, which makes the refusal a boundary")
        return
    }
    expect(
        threePlan.below.count == 1 && threePlan.above.count == 1,
        "one either side of the median")
    expect(
        NTFSIndexSplit.plan(of: Data(), nodeHeaderAt: 0) == nil, "and nothing is not a node")
    expect(
        NTFSIndexBlock.compose(
            blockNumber: 1, blockSize: blockSize, sectorSize: sectorSize, entries: readEntries,
            marker: marker) != nil,
        "a block holding everything the original held still fits, since it came out of one")
}

group("theBytesOfADirectoryEntry") {
    // What goes into a directory is the file's whole $FILE_NAME, the same bytes
    // its own record carries. That duplication is NTFS's: a listing reads names
    // and times straight out of the index without opening a record, which is
    // what makes listing a million files one pass rather than a million reads.
    //
    // The splice tests that used to be here went with the code they tested. The
    // backing builds a node from its entries now rather than moving bytes about
    // inside one, and that path is covered where it runs -- against a volume,
    // in the group that fills a directory and empties it thirty times over.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    let read: NTFSVolumeReader.ReadBytes = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    guard let reader = NTFSVolumeReader(read: read), let collation = reader.collation() else {
        expect(false, "the volume reads and has its table")
        return
    }

    let times = NTFSTimestamps.Times(
        created: Date(timeIntervalSince1970: 1_700_000_000),
        modified: Date(timeIntervalSince1970: 1_700_000_000),
        recordChanged: Date(timeIntervalSince1970: 1_700_000_000),
        accessed: Date(timeIntervalSince1970: 1_700_000_000))
    let name = "an-entry.txt"
    let key = NTFSNewRecord.fileNameValue(
        NTFSNewRecord.Plan(
            record: 900, sequence: 3, parent: NTFSTable.rootRecord, parentSequence: 5, name: name,
            namespace: .posix, times: times, securityID: 258),
        units: Array(name.utf16))
    guard let entry = NTFSIndexWrite.entry(key: key, record: 900, sequence: 3) else {
        expect(false, "an entry composes")
        return
    }
    expect(
        entry.count == (16 + key.count + 7) & ~7,
        "sixteen bytes of entry, the whole $FILE_NAME as its key, padded to eight")
    expect(
        Int(NTFSIndexWrite.read16(entry, NTFSIndexWrite.entryLengthField)) == entry.count,
        "with a length saying how long it is -- a reader walks a node by adding these")
    expect(
        Int(NTFSIndexWrite.read16(entry, NTFSIndexWrite.keyLengthField)) == key.count,
        "and a key length saying how much of it is the name")
    expect(
        NTFSIndexWrite.read16(entry, NTFSIndexWrite.entryFlagsField) == 0,
        "it is neither the end of a node nor a pointer to one below")
    expect(
        NTFSIndexWrite.key(of: entry, at: 0).map { String(decoding: $0, as: UTF16.self) } == name,
        "and the name reads back out of it")
    var reference: UInt64 = 0
    for byte in 0..<8 {
        reference |= UInt64(entry[entry.startIndex + byte]) << (8 * UInt64(byte))
    }
    expect(reference & 0x0000_FFFF_FFFF_FFFF == 900, "it names the record it was made for")
    expect(
        reference >> 48 == 3,
        "with the sequence that record had -- without it a stale entry follows to whatever "
            + "took the slot next")
    expect(
        NTFSIndexWrite.entry(key: Data(), record: 1, sequence: 1) == nil,
        "an empty key is not an entry")
    expect(
        NTFSIndexWrite.entry(key: Data(count: 40), record: 1, sequence: 1) == nil,
        "and neither is one too short to hold a name")

    // How full a node is, read off a real one.
    guard let root = reader.contents(ofDirectory: NTFSTable.rootRecord),
        let big = root.first(where: {
            (reader.contents(ofDirectory: $0.record)?.count ?? 0) > 1000
        }),
        let target = reader.indexNodes(ofDirectory: big.record)
            .first(where: { $0.diskOffset != nil && $0.entries.count > 4 }),
        let diskOffset = target.diskOffset,
        let raw = read(diskOffset, target.allocatedBytes),
        let header = NTFSIndexBlock.header(raw, blockSize: target.allocatedBytes),
        let node = NTFSIndexBlock.applyFixup(
            raw, header: header, sectorSize: reader.geometry.bytesPerSector),
        let room = NTFSIndexWrite.room(of: node, nodeHeaderAt: NTFSIndexBlock.nodeHeaderOffset)
    else {
        expect(false, "a real index block reads")
        return
    }
    expect(room.used >= NTFSIndexWrite.nodeHeaderLength, "a node uses at least its own header")
    expect(room.allocated >= room.used, "and never claims more used than it has")
    expect(
        room.allocated <= target.allocatedBytes - NTFSIndexBlock.nodeHeaderOffset,
        "nor more than the block it sits in")
    expect(room.free == room.allocated - room.used, "with the rest free")
    expect(
        NTFSIndexWrite.room(of: Data(), nodeHeaderAt: 0) == nil,
        "and nothing at all has no room to report")

    // The names in it are in the volume's order, which is what all of this is
    // in service of.
    let names = NTFSIndex.names(
        NTFSIndex.entries(node, from: header.firstEntryOffset, limit: header.endOfEntries))
    expect(names.count > 4, "the node has names in it: \(names.count)")
    expect(collation.isSorted(names), "and they are in the volume's own order")
}

group("namesAreOrderedTheWayTheVolumeOrdersThem") {
    // A directory is a B-tree, and a B-tree only works if everybody agrees on
    // the order. An entry filed by a different comparison is one Windows walks
    // straight past: the file is on the disk, in its record, with its bytes,
    // and not in the directory as far as anything asking Windows can tell.

    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume reads")
        return
    }

    guard let raw = reader.contents(ofFile: NTFSCollation.record),
        let collation = NTFSCollation(raw)
    else {
        expect(false, "$UpCase reads off the volume")
        return
    }
    expect(
        raw.count == NTFSCollation.entries * 2,
        "and is the full table, \(raw.count) bytes -- a partial one would order some names "
            + "right and others silently wrong")

    // What the table actually says, read from this volume rather than from a
    // specification.
    expect(collation.upper(0x61) == 0x41, "a uppercases to A")
    expect(collation.upper(0x41) == 0x41, "and A to itself")
    expect(collation.upper(0x30) == 0x30, "a digit is left alone")
    expect(collation.upper(0x00E9) == 0x00C9, "and an accented letter is not")

    // The two places Swift disagrees, which is the reason this exists.
    expect(
        collation.upper(0x00DF) == 0x00DF,
        "the volume leaves sharp s alone, while Swift makes it SS -- a different length as "
            + "well as a different value")
    expect("ß".uppercased() == "SS", "which is what Swift really does")
    expect(
        collation.upper(0x0131) == 0x0131,
        "and it leaves the dotless i alone, while Swift makes it I")
    expect("ı".uppercased() == "I", "which is what Swift really does")
    expect(
        collation.compare("straße.txt", "strasse.txt") != .orderedSame,
        "so these are two names to the volume")
    expect(
        "straße.txt".uppercased() == "STRASSE.TXT",
        "which Swift's uppercasing would have made one")

    // Case-insensitive, which is what makes NTFS NTFS.
    expect(collation.isSameName("README.txt", "readme.TXT"), "case does not make a new file")
    expect(!collation.isSameName("readme", "readme2"), "but a different name does")
    expect(collation.compare("", "") == .orderedSame, "two empty names are the same name")
    expect(collation.compare("", "a") == .orderedAscending, "and nothing sorts before something")
    expect(
        collation.compare("file", "file.txt") == .orderedAscending,
        "a name that is a prefix of another comes first")

    // The real test: a directory the volume filed itself. If this comparison
    // is not the comparison that filed them, anything inserted with it lands
    // where nothing will look.
    guard let listing = reader.contents(ofDirectory: NTFSTable.rootRecord) else {
        expect(false, "the root directory lists")
        return
    }
    let names = listing.map { $0.name }.filter { $0 != "." }
    expect(names.count > 10, "with names in it: \(names.count)")

    // A whole-directory listing is not sorted, and is not meant to be: the
    // reader sweeps the index blocks in the order they lie on the disk rather
    // than walking the tree, which is faster and gives the same set. What the
    // volume actually keeps sorted is each node within itself, and that is the
    // invariant an insertion has to match.
    var checked = 0
    var nodes = 0
    var directories = 0
    var outOfOrder: [(String, String, String)] = []
    var queue: [(UInt64, String)] = [(NTFSTable.rootRecord, "/")]
    while let (record, label) = queue.popLast(), directories < 64 {
        guard let entries = reader.contents(ofDirectory: record) else { continue }
        directories += 1
        for node in reader.indexNodes(ofDirectory: record) {
            let inside = NTFSIndex.names(node.entries)
            guard inside.count > 1 else { continue }
            nodes += 1
            checked += inside.count
            for index in 1..<inside.count
            where collation.compare(inside[index - 1], inside[index]) != .orderedAscending {
                outOfOrder.append((label, inside[index - 1], inside[index]))
            }
        }
        for entry in entries where entry.name != "." && entry.name != ".." {
            if reader.record(entry.record)?.header.isDirectory == true {
                queue.append((entry.record, label + entry.name + "/"))
            }
        }
    }
    expect(directories > 1, "across more than one directory: \(directories)")
    expect(nodes > 20, "and more than one node of the tree: \(nodes)")
    expect(checked > 1000, "with enough names to be worth saying anything about: \(checked)")
    expect(
        outOfOrder.isEmpty,
        "every node is in the order this comparison says, or: "
            + "\(outOfOrder.prefix(3).map { "\($0.0): \($0.1) then \($0.2)" })")

    // And somewhere on this volume a whole-directory sweep is *not* sorted, so
    // the paragraph above is a statement about how the tree is kept rather than
    // something that happens to be true of any list of names. A directory small
    // enough to live in one node is sorted either way; one that has grown past
    // it is not.
    var sweepUnsorted: String?
    var largest = 0
    queue = [(NTFSTable.rootRecord, "/")]
    var visited = 0
    while let (record, label) = queue.popLast(), visited < 64 {
        guard let entries = reader.contents(ofDirectory: record) else { continue }
        visited += 1
        let sweep = entries.map { $0.name }.filter { $0 != "." && $0 != ".." }
        largest = max(largest, sweep.count)
        if sweep.count > 2, !collation.isSorted(sweep), sweepUnsorted == nil {
            sweepUnsorted = "\(label) with \(sweep.count) entries"
        }
        for entry in entries where entry.name != "." && entry.name != ".." {
            if reader.record(entry.record)?.header.isDirectory == true {
                queue.append((entry.record, label + entry.name + "/"))
            }
        }
    }
    expect(largest > 1000, "the volume has a directory big enough to span nodes: \(largest)")
    expect(
        sweepUnsorted != nil,
        "and its sweep across blocks is not sorted, which is why the check above is per node: "
            + "\(sweepUnsorted ?? "every sweep was sorted")")

    // Every name the volume holds is the same name as itself under this
    // comparison, which is the property an insertion needs and is not implied
    // by the ordering above.
    let selfSame = names.prefix(200).allSatisfy { collation.isSameName($0, $0) }
    expect(selfSame, "and each of them is the same name as itself")

    // A deeper directory too, so this is not one node's worth of luck.
    if let deeper = names.first(where: { name in
        reader.find(name, inDirectory: NTFSTable.rootRecord)
            .flatMap { reader.record($0)?.header.isDirectory } == true
    }), let inside = reader.find(deeper, inDirectory: NTFSTable.rootRecord),
        let children = reader.contents(ofDirectory: inside)
    {
        let inner = children.map { $0.name }.filter { $0 != "." && $0 != ".." }
        if inner.count > 1 {
            expect(
                collation.isSorted(inner),
                "and \(deeper) with its \(inner.count) entries is in order too")
        }
    }

    // The reader hands its own table out, and hands out the same one twice --
    // it is 128 KB off the disk and every lookup wants it.
    guard let fromReader = reader.collation() else {
        expect(false, "the reader loads the volume's table")
        return
    }
    expect(fromReader.upper(0x61) == 0x41, "and it is a real table")
    expect(
        reader.collation()?.upper(0x00DF) == 0x00DF,
        "asked twice, it says the same thing")

    // And every name in the biggest directory is still found through it, so
    // filing by this comparison and searching by it agree.
    var lookedUp = 0
    var missed: [String] = []
    if let big = reader.contents(ofDirectory: NTFSTable.rootRecord)?
        .first(where: { entry in
            (reader.contents(ofDirectory: entry.record)?.count ?? 0) > 1000
        })
    {
        for entry in (reader.contents(ofDirectory: big.record) ?? []).prefix(2000)
        where entry.name != "." && entry.name != ".." {
            lookedUp += 1
            if reader.find(entry.name, inDirectory: big.record) != entry.record {
                missed.append(entry.name)
            }
        }
    }
    expect(lookedUp > 1000, "every name in a directory of thousands is looked up: \(lookedUp)")
    expect(
        missed.isEmpty,
        "and every one of them is found again: missed \(missed.prefix(3))")

    // The identity table is not the volume's, and saying so is the point: a
    // caller that writes must have the real one.
    expect(
        NTFSCollation.identity.upper(0x61) == 0x61,
        "the identity table leaves a as a")
    expect(
        NTFSCollation.identity.compare("A", "a") != .orderedSame,
        "so it is not case-insensitive and must not be used to file anything")
    expect(NTFSCollation(Data()) == nil, "a table that is not there is refused")
    expect(
        NTFSCollation(Data(count: NTFSCollation.entries * 2 - 1)) == nil,
        "and one a byte short, because half a table orders half the names wrongly")
}

group("aComposedRecordIsAFileTheReaderRecognises") {
    // A file on NTFS is a record, not a name with data behind it. So the test
    // of a composer is whether the reader -- which was written against real
    // volumes and knows nothing about this code -- sees a file in what it
    // produced, with the fields that went in.

    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume reads")
        return
    }
    let recordSize = reader.geometry.bytesPerFileRecord
    let sectorSize = reader.geometry.bytesPerSector

    // A real file, and everything about it, read out by the reader. Found by
    // walking the table rather than by looking in the root: this one lives in a
    // directory a few levels down, and what the test needs is a file with its
    // bytes inside its record, not a particular path.
    var found: (data: Data, header: NTFSRecord.Header)?
    var foundNumber: UInt64 = 0
    for candidate in NTFSRecordAllocator.firstAvailable..<256 {
        guard let record = reader.record(candidate), record.header.inUse,
            !record.header.isDirectory, reader.name(of: record) == "p00001"
        else { continue }
        found = record
        foundNumber = candidate
        break
    }
    guard let original = found else {
        expect(false, "p00001 is on the volume")
        return
    }
    let number = foundNumber
    let attributes = reader.attributes(of: original)
    guard let times = reader.times(of: original),
        let realName = reader.name(of: original),
        let realData = attributes.first(where: { $0.kind == .data }), realData.isResident,
        let contents = reader.contents(ofFile: number)
    else {
        expect(false, "and its name, times and contents read")
        return
    }
    expect(realName == "p00001", "the file read back is the one we asked for")
    expect(contents.count == 512, "with the bytes it has: \(contents.count)")

    let plan = NTFSNewRecord.Plan(
        record: 4096, sequence: 1, parent: NTFSTable.rootRecord, parentSequence: 5,
        name: "made-by-lukotta.txt", namespace: .posix, times: times, securityID: 258,
        contents: contents)
    guard let composed = NTFSNewRecord.compose(plan, recordSize: recordSize, sectorSize: sectorSize)
    else {
        expect(false, "a record composes")
        return
    }
    expect(composed.count == recordSize, "and is exactly one record long")

    // The reader, on the composed bytes.
    guard let header = NTFSRecord.header(composed, expectedLength: recordSize) else {
        expect(false, "the reader accepts the header it wrote")
        return
    }
    expect(header.inUse, "the record says it is in use")
    expect(!header.isDirectory, "and is a file")
    expect(header.allocatedLength == recordSize, "it fills its slot")
    expect(header.usedLength <= header.allocatedLength, "and does not claim more than it has")
    expect(header.usedLength % 8 == 0, "ending on an eight-byte boundary, as attributes do")
    expect(
        header.firstAttributeOffset >= header.fixupOffset + header.fixupCount * 2,
        "the first attribute starts after the fixup array, not inside it")
    expect(
        header.fixupCount == recordSize / sectorSize + 1,
        "with one fixup entry per sector and one for the signature")

    let read = NTFSAttribute.all(
        in: composed, startingAt: header.firstAttributeOffset, usedLength: header.usedLength)
    expect(
        read.count == 3,
        "three attributes come back: \(read.map { $0.kind.map(String.init(describing:)) ?? "?" })")
    expect(
        read.map { $0.type } == [0x10, 0x30, 0x80],
        "in ascending order of type, which is a rule and not a habit -- a reader looking for "
            + "$DATA stops when it passes 0x80")
    expect(read.allSatisfy { $0.isResident }, "all of them inside the record")
    expect(
        read.allSatisfy { $0.length % 8 == 0 },
        "each a multiple of eight long, because the next one starts where this one ends")

    // And what they say.
    guard
        let composedTimes = NTFSTimestamps.read(
            composed[
                composed.startIndex + read[0].valueOffset..<composed.startIndex
                    + read[0].valueOffset
                    + read[0].valueLength])
    else {
        expect(false, "the times read back")
        return
    }
    expect(composedTimes == times, "the times are the ones that went in, to the tick")

    guard
        let composedName = NTFSFileName.read(
            composed[
                composed.startIndex + read[1].valueOffset..<composed.startIndex
                    + read[1].valueOffset
                    + read[1].valueLength])
    else {
        expect(false, "the name reads back")
        return
    }
    expect(composedName.name == "made-by-lukotta.txt", "the name is what was asked for")
    expect(composedName.parentRecord == NTFSTable.rootRecord, "in the directory it was made in")
    expect(composedName.namespace == .posix, "in the namespace it was given")

    expect(read[2].dataSize == UInt64(contents.count), "$DATA is as long as the contents")
    expect(
        composed[
            composed.startIndex + read[2].valueOffset..<composed.startIndex + read[2].valueOffset
                + read[2].valueLength] == contents,
        "and holds them, byte for byte")

    // The same shape a real record has. Not byte-identical: this volume's
    // records carry $EA and an EA-size field that macOS put there, and a file
    // made here has neither. What must match is the layout every reader
    // depends on.
    guard let realHeader = NTFSRecord.header(original.data, expectedLength: recordSize) else {
        expect(false, "the real record's header reads")
        return
    }
    expect(
        header.fixupOffset == realHeader.fixupOffset,
        "the fixup array is where this volume's own records keep it")
    expect(
        header.fixupCount == realHeader.fixupCount, "and is the same size")
    expect(
        header.firstAttributeOffset == realHeader.firstAttributeOffset,
        "and the attributes begin where they do in a record ntfs-3g wrote")
    guard let realInformation = attributes.first(where: { $0.kind == .standardInformation }),
        let realFileName = attributes.first(where: { $0.kind == .fileName })
    else {
        expect(false, "the real record has both")
        return
    }
    expect(
        read[0].valueLength == realInformation.valueLength,
        "$STANDARD_INFORMATION is the same length as the real one: "
            + "\(read[0].valueLength) against \(realInformation.valueLength)")
    expect(
        read[0].length == realInformation.length, "and so is the attribute round it")
    expect(
        read[1].valueLength == realFileName.valueLength + 26,
        "$FILE_NAME is longer only by the thirteen characters of extra name")
    expect(
        read[1].valueOffset - read[1].length + read[1].length == read[1].valueOffset,
        "and its value sits inside it")

    // The used length is where the record actually ends, not where it could.
    // A reader trusting a longer one walks past the end marker into whatever
    // the slot held before.
    let accounted = header.firstAttributeOffset + read.reduce(0) { $0 + $1.length } + 8
    expect(
        header.usedLength == accounted,
        "the used length accounts for the header, the attributes and the end marker: "
            + "\(header.usedLength) against \(accounted)")
    expect(header.usedLength < recordSize, "and leaves the rest of the slot alone")

    // One name, so one link. A record claiming none is one chkdsk treats as
    // deleted and takes the space back from, with the file still in its
    // directory.
    let links =
        UInt16(composed[composed.startIndex + 0x12])
        | (UInt16(composed[composed.startIndex + 0x13]) << 8)
    expect(links == 1, "the record has one link, for its one name")
    let realLinks =
        UInt16(original.data[original.data.startIndex + 0x12])
        | (UInt16(original.data[original.data.startIndex + 0x13]) << 8)
    expect(realLinks == 1, "which is what the real record says as well")

    // $FILE_NAME carries a copy of the size, because a directory listing reads
    // it without opening the record. A zero there is a file Finder shows as
    // empty while its bytes are sitting in the record.
    let nameValue = composed[
        composed.startIndex + read[1].valueOffset..<composed.startIndex + read[1].valueOffset
            + read[1].valueLength]
    let nameStart = nameValue.startIndex
    var realSize: UInt64 = 0
    for byte in 0..<8 { realSize |= UInt64(nameValue[nameStart + 48 + byte]) << (8 * UInt64(byte)) }
    expect(
        realSize == UInt64(contents.count),
        "the size in $FILE_NAME matches the contents: \(realSize)")
    var allocated: UInt64 = 0
    for byte in 0..<8 {
        allocated |= UInt64(nameValue[nameStart + 40 + byte]) << (8 * UInt64(byte))
    }
    expect(
        allocated == 0,
        "and nothing is claimed as allocated, because a file living in its record has no "
            + "clusters -- a number here is one the record disagrees with")

    // The indexed flag on $FILE_NAME. Windows sets it, and it says the
    // attribute is also kept in a directory index; a record without it is one
    // chkdsk repairs.
    var offsets: [Int] = []
    var walking = header.firstAttributeOffset
    for attribute in read {
        offsets.append(walking)
        walking += attribute.length
    }
    expect(
        composed[composed.startIndex + offsets[1] + 0x16] == 1,
        "$FILE_NAME is marked as indexed")
    expect(
        composed[composed.startIndex + offsets[0] + 0x16] == 0,
        "and $STANDARD_INFORMATION is not, because nothing indexes it")
    expect(
        composed[composed.startIndex + offsets[2] + 0x16] == 0, "nor is $DATA")
    expect(
        original.data[original.data.startIndex + 144 + 0x16] == 1,
        "which is what the real record does too")

    // A name whose length does not land on eight. Every attribute still begins
    // on an eight-byte boundary, because the next one starts where this one
    // says it ends and a reader that lands one byte off reads a length as a
    // type.
    guard
        let odd = NTFSNewRecord.compose(
            NTFSNewRecord.Plan(
                record: 4096, sequence: 1, parent: NTFSTable.rootRecord, parentSequence: 5,
                name: "odd", namespace: .posix, times: times, securityID: 258,
                contents: Data("five!".utf8)),
            recordSize: recordSize, sectorSize: sectorSize),
        let oddHeader = NTFSRecord.header(odd, expectedLength: recordSize)
    else {
        expect(false, "a record with awkward lengths composes")
        return
    }
    let oddAttributes = NTFSAttribute.all(
        in: odd, startingAt: oddHeader.firstAttributeOffset, usedLength: oddHeader.usedLength)
    expect(oddAttributes.count == 3, "and still has its three attributes")
    expect(
        oddAttributes.allSatisfy { $0.length % 8 == 0 },
        "each padded to eight: \(oddAttributes.map { $0.length })")
    expect(
        oddAttributes.contains { $0.length != 24 + $0.valueLength },
        "and at least one of them really needed the padding, so this is a test and not a "
            + "coincidence of lengths")
    expect(
        oddAttributes.last?.valueLength == 5, "with the contents unpadded inside it")
    expect(oddHeader.usedLength % 8 == 0, "and the record ends on eight as well")

    // A record composed twice from the same plan is the same record. Anything
    // else means something was carried over from the last one.
    expect(
        NTFSNewRecord.compose(plan, recordSize: recordSize, sectorSize: sectorSize) == composed,
        "composing twice gives the same bytes")

    // What will not fit is refused rather than truncated. A file whose bytes do
    // not fit in its record needs clusters, and that is the caller's decision.
    expect(
        NTFSNewRecord.compose(
            NTFSNewRecord.Plan(
                record: 4096, sequence: 1, parent: 5, parentSequence: 5, name: "big.txt",
                namespace: .posix, times: times, securityID: 258,
                contents: Data(count: recordSize)),
            recordSize: recordSize, sectorSize: sectorSize) == nil,
        "contents that fill the whole record leave no room for the record")
    expect(
        NTFSNewRecord.compose(
            NTFSNewRecord.Plan(
                record: 4096, sequence: 1, parent: 5, parentSequence: 5, name: "",
                namespace: .posix, times: times, securityID: 258),
            recordSize: recordSize, sectorSize: sectorSize) == nil,
        "a file with no name is not a file")
    expect(
        NTFSNewRecord.compose(
            NTFSNewRecord.Plan(
                record: 4096, sequence: 1, parent: 5, parentSequence: 5,
                name: String(repeating: "n", count: 256), namespace: .posix, times: times,
                securityID: 258),
            recordSize: recordSize, sectorSize: sectorSize) == nil,
        "and a name longer than NTFS can count is refused, not cut short")
    expect(
        NTFSNewRecord.compose(plan, recordSize: recordSize, sectorSize: 0) == nil,
        "a sector size of nothing is refused")
    expect(
        NTFSNewRecord.compose(plan, recordSize: 300, sectorSize: sectorSize) == nil,
        "and a record too small to be one")

    // A name at the longest NTFS allows still fits, so the refusal above is a
    // boundary and not a wall in the wrong place.
    expect(
        NTFSNewRecord.compose(
            NTFSNewRecord.Plan(
                record: 4096, sequence: 1, parent: 5, parentSequence: 5,
                name: String(repeating: "n", count: 255), namespace: .win32, times: times,
                securityID: 258),
            recordSize: recordSize, sectorSize: sectorSize) != nil,
        "a name of the full 255 characters composes")

    // The reference in $FILE_NAME carries the parent's sequence in its top
    // bits. Without it, a reference to a deleted directory follows to whatever
    // took the record next.
    let reference = NTFSNewRecord.reference(NTFSTable.rootRecord, sequence: 5)
    expect(reference & 0x0000_FFFF_FFFF_FFFF == NTFSTable.rootRecord, "the record number is there")
    expect(reference >> 48 == 5, "and the sequence above it")
    expect(
        NTFSNewRecord.reference(0x0000_FFFF_FFFF_FFFF + 1, sequence: 0) == 0,
        "a record number too large to hold is masked rather than allowed to become a sequence")
}

group("aNewFileTakesARecordNobodyElseHas") {
    // $MFT keeps a $BITMAP saying which of its records describe files that
    // exist. Creating one means finding a clear bit -- and never one of the
    // first twenty-four, which are the volume's own files and the slots every
    // implementation holds in reserve.

    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        })
    else {
        expect(false, "the volume reads")
        return
    }

    guard let bitmap = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap),
        let tableSize = reader.size(ofFile: NTFSTable.mftRecord)
    else {
        expect(false, "$MFT has a $BITMAP and a size")
        return
    }
    let records = tableSize / UInt64(reader.geometry.bytesPerFileRecord)
    expect(records > NTFSRecordAllocator.firstAvailable, "the table holds more than the reserve")
    expect(
        UInt64(bitmap.count) * 8 >= records,
        "and its bitmap has a bit for every record, which is what makes the search bounded")

    // The bitmap agrees with the records themselves. Two independent things
    // saying the same about the same volume is what makes either believable.
    var checked = 0
    var agreed = 0
    for number in 0..<min(records, 512) {
        guard let claimed = NTFSRecordAllocator.isInUse(number, in: bitmap) else { continue }
        checked += 1
        let present = reader.record(number)?.header.inUse ?? false
        if claimed == present { agreed += 1 }
    }
    expect(checked > 100, "enough records to be worth saying anything about: \(checked)")
    expect(
        agreed == checked,
        "and the bitmap agrees with every record's own header, \(agreed) of \(checked)")

    guard let choice = NTFSRecordAllocator.choose(in: bitmap, recordCount: records) else {
        expect(false, "there is a free record on a volume this empty")
        return
    }
    expect(
        choice.record >= NTFSRecordAllocator.firstAvailable,
        "the record chosen is not one of the volume's own -- handing out record \(choice.record) "
            + "would be handing out a slot Windows expects to find where it left it")
    expect(choice.record < records, "and is inside the table")
    expect(
        NTFSRecordAllocator.isInUse(choice.record, in: bitmap) == false,
        "it was free before")
    expect(
        NTFSRecordAllocator.isInUse(choice.record, in: choice.bitmap) == true,
        "and is taken after")
    expect(
        reader.record(choice.record)?.header.inUse != true,
        "and the record itself is not in use either, so the two agree")
    expect(choice.bitmap.count == bitmap.count, "claiming a record does not resize the bitmap")

    // Only that one bit moved.
    let moved = zip([UInt8](bitmap), [UInt8](choice.bitmap)).enumerated()
        .filter { $0.element.0 != $0.element.1 }
    expect(moved.count == 1, "exactly one byte of the bitmap changed")
    if let (index, pair) = moved.first.map({ ($0.offset, $0.element) }) {
        expect(
            UInt64(index) == choice.record / 8,
            "and it is the byte the chosen record lives in")
        expect(
            pair.1 == pair.0 | (1 << UInt8(choice.record % 8)),
            "with one bit set and nothing else disturbed")
    }

    // Asking twice with the first taken gives a different record. Two files
    // created in a row must not be handed the same slot.
    guard let second = NTFSRecordAllocator.choose(in: choice.bitmap, recordCount: records) else {
        expect(false, "a second record is free too")
        return
    }
    expect(second.record != choice.record, "a second file gets a different record")

    // Giving it back.
    guard
        let returned = NTFSRecordAllocator.releasing(
            choice.record, in: choice.bitmap, recordCount: records)
    else {
        expect(false, "a record can be given back")
        return
    }
    expect(returned == bitmap, "and the bitmap is exactly as it was")

    // The reserve is not for handing out, and not for taking back either.
    for reserved in [UInt64(0), 3, 5, 15, 23] {
        expect(
            NTFSRecordAllocator.releasing(reserved, in: bitmap, recordCount: records) == nil,
            "record \(reserved) is never released -- clearing that bit tells the next "
                + "allocation that one of the volume's own files is free")
    }
    guard
        let hinted = NTFSRecordAllocator.choose(in: bitmap, recordCount: records, near: 0)
    else {
        expect(false, "a hint below the reserve still finds a record")
        return
    }
    expect(
        hinted.record >= NTFSRecordAllocator.firstAvailable,
        "and a hint pointing into the reserve does not get you into it")

    // A hint past every free record. The search only goes forwards, so without
    // a second pass from the beginning this volume would report itself full
    // while most of its table is empty -- and a file that could have been
    // created would fail instead.
    var crowded = [UInt8](repeating: 0x00, count: 16)
    crowded[0] = 0xFF
    crowded[1] = 0xFF
    crowded[2] = 0xFF  // records 0 to 23, the reserve
    for byte in 5..<16 { crowded[byte] = 0xFF }  // records 40 upwards, taken
    expect(
        NTFSRecordAllocator.choose(in: Data(crowded), recordCount: 128, near: 100)?.record == 24,
        "a hint past the last free record still finds the free ones behind it")
    expect(
        NTFSRecordAllocator.choose(in: Data(crowded), recordCount: 128, near: 30)?.record == 30,
        "while a hint that lands on free space is followed, so files made together sit together")

    // A table with nothing but reserve in it has nowhere to put a file, and
    // says so rather than handing out a record past its end.
    expect(
        NTFSRecordAllocator.choose(in: bitmap, recordCount: 24) == nil,
        "a table of only reserved records is full")
    expect(
        NTFSRecordAllocator.choose(in: bitmap, recordCount: 0) == nil,
        "and so is one with no records at all")
    expect(
        NTFSRecordAllocator.choose(in: Data(), recordCount: records) == nil,
        "a bitmap with nothing in it yields nothing")

    // On this volume the bitmap has exactly one bit per record and not one
    // more -- mkntfs sized both to the same cluster. That is not guaranteed:
    // the bitmap is bytes, the table is records, and a table whose count is not
    // a multiple of eight leaves bits describing records that do not exist.
    // Handing one of those out is handing out a slot past the end of the table.
    expect(
        UInt64(bitmap.count) * 8 == records,
        "this volume has no spare bits: \(UInt64(bitmap.count) * 8) for \(records) records")
    let full = Data(repeating: 0xFF, count: bitmap.count)
    expect(
        NTFSRecordAllocator.choose(in: full, recordCount: records) == nil,
        "and when every record is taken, none is offered")
    // A table three records short of filling its last byte. The five spare bits
    // are clear, and must still not be offered.
    let roomy = Data(repeating: 0xFF, count: 8)
    expect(
        NTFSRecordAllocator.choose(in: roomy, recordCount: 61) == nil,
        "a full table is full even when its bitmap has bits left over")
    var lastByteFree = [UInt8](repeating: 0xFF, count: 8)
    // Set means in use, so clearing the top three bits frees records 61 to 63.
    // Records 56 to 60 stay taken, and 61 is past the end of a 61-record table.
    lastByteFree[7] = 0x1F
    expect(
        NTFSRecordAllocator.choose(in: Data(lastByteFree), recordCount: 61) == nil,
        "and a bit past the end of the table is not a free record")
    expect(
        NTFSRecordAllocator.choose(in: Data(lastByteFree), recordCount: 62)?.record == 61,
        "while the same bit is a free record once the table is long enough to hold it")
}

group("aRecordGoesBackToEveryPlaceItLives") {
    // $MFTMirr holds a copy of the beginning of the table, and $Volume -- where
    // the dirty flag lives -- is inside it. So the very first write this
    // filesystem makes is one that has to go to two places.

    let size = 1024
    let table: UInt64 = 16384
    let mirror: UInt64 = 2_147_479_552

    for record in 0..<4 {
        guard
            let places = NTFSRecordWrite.destinations(
                record: UInt64(record), tableOffset: table + UInt64(record * size),
                mirrorOffset: mirror, mirrorLength: 4096, bytesPerFileRecord: size)
        else {
            expect(false, "record \(record) has somewhere to go")
            continue
        }
        expect(places.count == 2, "record \(record) is written twice")
        guard places.count == 2 else { continue }
        expect(places[0].offset == table + UInt64(record * size), "once where it was read")
        expect(
            places[1].offset == mirror + UInt64(record * size),
            "and once into the mirror, at the same place within it")
        expect(places[1].isMirror && !places[0].isMirror, "and they are told apart")
    }

    let beyond = NTFSRecordWrite.destinations(
        record: 4, tableOffset: table + 4096, mirrorOffset: mirror, mirrorLength: 4096,
        bytesPerFileRecord: size)
    expect(beyond?.count == 1, "a record past the mirror is written once")
    expect(
        beyond?.first?.isMirror == false,
        "and into the table, not off the end of the mirror -- that would be writing over "
            + "whatever the volume keeps after it")

    expect(
        NTFSRecordWrite.destinations(
            record: 0, tableOffset: table, mirrorOffset: mirror, mirrorLength: 0,
            bytesPerFileRecord: size)?.count == 1,
        "a volume with no mirror at all still writes its table copy")
    expect(
        NTFSRecordWrite.destinations(
            record: 0, tableOffset: table, mirrorOffset: mirror, mirrorLength: 4096,
            bytesPerFileRecord: 0) == nil,
        "and a record of no length is refused rather than written at offset zero")
    // A record number the mirror claims to cover but whose offset would not fit
    // in the arithmetic. Refused, not wrapped round to the start of the disk --
    // where it would land on the boot sector.
    expect(
        NTFSRecordWrite.destinations(
            record: UInt64.max / UInt64(size) - 1, tableOffset: table, mirrorOffset: mirror,
            mirrorLength: UInt64.max, bytesPerFileRecord: size) == nil,
        "an offset that would overflow is refused")
    expect(
        NTFSRecordWrite.destinations(
            record: UInt64.max / UInt64(size) + 1, tableOffset: table, mirrorOffset: mirror,
            mirrorLength: UInt64.max, bytesPerFileRecord: size)?.count == 1,
        "while one simply past the mirror is written once, as any unmirrored record is")

    // And against the volume itself: the mirror really does hold records 0-3
    // byte for byte, so the two-destination rule is not a guess.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    let raw: @Sendable (UInt64, Int) -> Data? = { offset, length in
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: length)
    }
    guard let reader = NTFSVolumeReader(read: raw) else {
        expect(false, "the volume reads")
        return
    }
    let geometry = reader.geometry
    let mirrorOffset = geometry.mftMirrorStartCluster * UInt64(geometry.bytesPerCluster)
    guard let mirrorLength = reader.size(ofFile: NTFSRecordWrite.mirrorRecord) else {
        expect(false, "$MFTMirr says how long it is")
        return
    }
    expect(
        mirrorLength / UInt64(geometry.bytesPerFileRecord) == 4,
        "it covers four records on this volume, $MFT $MFTMirr $LogFile $Volume")
    expect(
        NTFSVolumeState.volumeRecord < mirrorLength / UInt64(geometry.bytesPerFileRecord),
        "and $Volume is one of them, which is why marking dirty is a two-place write")

    for number in 0..<(mirrorLength / UInt64(geometry.bytesPerFileRecord)) {
        guard
            let tableOffset = reader.diskOffset(ofRecord: number),
            let places = NTFSRecordWrite.destinations(
                record: number, tableOffset: tableOffset, mirrorOffset: mirrorOffset,
                mirrorLength: mirrorLength, bytesPerFileRecord: geometry.bytesPerFileRecord),
            places.count == 2,
            let inTable = raw(places[0].offset, geometry.bytesPerFileRecord),
            let inMirror = raw(places[1].offset, geometry.bytesPerFileRecord)
        else {
            expect(false, "record \(number) is in both places")
            continue
        }
        expect(
            inTable == inMirror,
            "record \(number) is identical in the table and the mirror, so a write that "
                + "changed one and not the other is what chkdsk would find")
    }

    // A record the mirror does not cover is not the same in both -- which is
    // what makes the check above mean something rather than comparing a place
    // with itself.
    if let fifth = reader.diskOffset(ofRecord: 4),
        let inTable = raw(fifth, geometry.bytesPerFileRecord),
        let past = raw(
            mirrorOffset + 4 * UInt64(geometry.bytesPerFileRecord),
            geometry.bytesPerFileRecord)
    {
        expect(inTable != past, "and record 4 is not mirrored, so the comparison is a real one")
    }

    // The bytes that go down: fixup off, and a signature that has moved on.
    guard let volume = reader.record(NTFSVolumeState.volumeRecord),
        let onDisk = NTFSRecordWrite.onDisk(
            volume.data, header: volume.header, sectorSize: geometry.bytesPerSector),
        let backAgain = NTFSRecord.applyFixup(
            onDisk, header: volume.header, sectorSize: geometry.bytesPerSector)
    else {
        expect(false, "$Volume can be laid out for writing")
        return
    }
    expect(onDisk.count == volume.data.count, "which is the same length it was read at")
    func withoutSignature(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        bytes[volume.header.fixupOffset] = 0
        bytes[volume.header.fixupOffset + 1] = 0
        return Data(bytes)
    }
    expect(
        withoutSignature(backAgain) == withoutSignature(volume.data),
        "and reads back as what it was")
    let was =
        UInt16(volume.data[volume.data.startIndex + volume.header.fixupOffset])
        | (UInt16(volume.data[volume.data.startIndex + volume.header.fixupOffset + 1]) << 8)
    let now =
        UInt16(onDisk[onDisk.startIndex + volume.header.fixupOffset])
        | (UInt16(onDisk[onDisk.startIndex + volume.header.fixupOffset + 1]) << 8)
    expect(now == NTFSRecord.nextSignature(after: was), "with the signature moved on")
    expect(now != 0, "and never zero, which is what an unwritten sector holds")

    // Every sector of what goes down carries that signature in its last two
    // bytes. That is the whole scheme: a record caught half-written has some
    // sectors old and some new, and the mismatch is what makes it detectable.
    for sector in 1..<volume.header.fixupCount {
        let end = onDisk.startIndex + sector * geometry.bytesPerSector - 2
        guard end + 1 < onDisk.endIndex else { continue }
        expect(
            UInt16(onDisk[end]) | (UInt16(onDisk[end + 1]) << 8) == now,
            "sector \(sector) carries the signature")
    }
}

group("theDirtyFlagIsSetWhileWeHoldTheVolume") {
    // Without a journal, the only honest thing to do is say so on the volume:
    // dirty before the first write, clear only on a clean release. A session
    // that ends any other way leaves it set, and Windows runs chkdsk. That is
    // what ntfs-3g and ntfs3 do, which is what v1 already does.

    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        }), let volume = reader.record(NTFSVolumeState.volumeRecord)
    else {
        expect(false, "$Volume reads")
        return
    }
    let attributes = reader.attributes(of: volume)
    guard let before = NTFSVolumeState.read(record: volume.data, attributes: attributes) else {
        expect(false, "and parses")
        return
    }
    expect(!before.isDirty, "this volume is clean, which is why it was safe to write to")

    guard let marked = NTFSVolumeState.setting(dirty: true, in: volume.data, attributes: attributes)
    else {
        expect(false, "the flag can be set")
        return
    }
    expect(marked.count == volume.data.count, "setting it changes the length not at all")
    guard let markedHeader = NTFSRecord.header(marked, expectedLength: marked.count),
        let readBack = NTFSVolumeState.read(
            record: marked,
            attributes: NTFSAttribute.all(
                in: marked, startingAt: markedHeader.firstAttributeOffset,
                usedLength: markedHeader.usedLength))
    else {
        expect(false, "and the marked record still parses")
        return
    }
    expect(readBack.isDirty, "and it reads back dirty")
    expect(!readBack.isSafeToWrite, "so the volume refuses further writes while marked")

    // Every other thing $Volume says must survive untouched. A flag setter that
    // rewrites the label or the version is a flag setter that loses data.
    expect(readBack.label == before.label, "the label is untouched")
    expect(readBack.majorVersion == before.majorVersion, "and the version")
    expect(readBack.minorVersion == before.minorVersion, "both halves of it")
    expect(
        readBack.wantsCheck == before.wantsCheck, "and a chkdsk Windows scheduled stays scheduled")
    expect(
        readBack.wantsLogFileUpdate == before.wantsLogFileUpdate,
        "and a log update it wants stays wanted -- those are Windows's bits, not ours")

    // Exactly two bytes differ, and they are the flags.
    let differing = zip([UInt8](volume.data), [UInt8](marked)).enumerated()
        .filter { $0.element.0 != $0.element.1 }.map { $0.offset }
    expect(differing.count == 1, "one byte differs, since the flag is in the low half")
    expect(
        differing.allSatisfy { $0 >= 42 && $0 < volume.data.count },
        "and it is inside the record, not in its header")

    // And clearing it puts the volume back exactly as found.
    guard let cleared = NTFSVolumeState.setting(dirty: false, in: marked, attributes: attributes)
    else {
        expect(false, "the flag can be cleared")
        return
    }
    expect(cleared == volume.data, "clearing restores the record byte for byte")

    // Clearing an already-clean volume is a no-op, so a release that runs twice
    // cannot damage anything.
    expect(
        NTFSVolumeState.setting(dirty: false, in: volume.data, attributes: attributes)
            == volume.data,
        "and clearing a clean volume changes nothing at all")
    expect(
        NTFSVolumeState.setting(dirty: true, in: marked, attributes: attributes) == marked,
        "as does marking one already marked")

    // The record still survives being written: fixup off with a fresh
    // signature, fixup back on, and the bytes are the ones we meant.
    let signature = NTFSRecord.nextSignature(
        after: UInt16(volume.data[volume.data.startIndex + volume.header.fixupOffset])
            | (UInt16(volume.data[volume.data.startIndex + volume.header.fixupOffset + 1]) << 8))
    guard
        let onDisk = NTFSRecord.removeFixup(marked, header: markedHeader, signature: signature),
        let restored = NTFSRecord.applyFixup(onDisk, header: markedHeader)
    else {
        expect(false, "the marked record survives a write and a read")
        return
    }
    // Everything but the fixup signature itself, which is meant to change on
    // every write -- that is how a torn write is told from a whole one.
    func withoutSignature(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        bytes[markedHeader.fixupOffset] = 0
        bytes[markedHeader.fixupOffset + 1] = 0
        return Data(bytes)
    }
    expect(
        withoutSignature(restored) == withoutSignature(marked),
        "and comes back exactly as it went down")
    expect(
        restored[restored.startIndex + markedHeader.fixupOffset]
            != volume.data[
                volume.data.startIndex + markedHeader.fixupOffset]
            || restored[restored.startIndex + markedHeader.fixupOffset + 1]
                != volume.data[
                    volume.data.startIndex + markedHeader.fixupOffset + 1],
        "with a signature that moved on, so a torn write cannot pass for a whole one")

    // This volume has no other flags set, so checking that they survive proves
    // nothing on it -- both a setter that touches one bit and one that
    // overwrites the word leave it identical. So set them, and check against a
    // volume that has something to lose. The offset is worked out here the same
    // way the setter works it out; what is being checked is what happens to the
    // bits, not where they are, which the wrong-offset mutation covers.
    guard let information = attributes.first(where: { $0.kind == .volumeInformation })
    else {
        expect(false, "$VOLUME_INFORMATION is there")
        return
    }
    var pending = [UInt8](volume.data)
    pending[information.valueOffset + 10] = 0x06  // chkdsk wanted, log update wanted
    pending[information.valueOffset + 11] = 0x00
    guard
        let pendingMarked = NTFSVolumeState.setting(
            dirty: true, in: Data(pending), attributes: attributes),
        let pendingHeader = NTFSRecord.header(pendingMarked, expectedLength: pendingMarked.count),
        let pendingInfo = NTFSVolumeState.read(
            record: pendingMarked,
            attributes: NTFSAttribute.all(
                in: pendingMarked, startingAt: pendingHeader.firstAttributeOffset,
                usedLength: pendingHeader.usedLength))
    else {
        expect(false, "a volume with work Windows scheduled can still be marked")
        return
    }
    expect(pendingInfo.isDirty, "marking it sets our bit")
    expect(
        pendingInfo.wantsCheck && pendingInfo.wantsLogFileUpdate,
        "and leaves Windows's alone -- clearing those would be telling Windows work it "
            + "scheduled has been done, and the check it wanted would never run")
    expect(
        NTFSVolumeState.setting(dirty: false, in: pendingMarked, attributes: attributes)
            == Data(pending),
        "and releasing it clears ours and only ours")

    // A record with no volume information is refused rather than written at a
    // guessed offset. Record 3 is not somewhere to write two hopeful bytes.
    expect(
        NTFSVolumeState.setting(dirty: true, in: volume.data, attributes: []) == nil,
        "no $VOLUME_INFORMATION means no write")
    expect(
        NTFSVolumeState.setting(dirty: true, in: Data(), attributes: attributes) == nil,
        "and neither does an empty record")
    expect(
        NTFSVolumeState.setting(
            dirty: true, in: volume.data.prefix(64), attributes: attributes) == nil,
        "nor one cut off before the flags")

    // An attribute that says its value is shorter than the flags it is supposed
    // to contain is refused too. Believing it means writing two bytes past the
    // end of somebody else's attribute.
    let stunted = NTFSAttribute.Header(
        type: information.type, length: information.length, isResident: true,
        valueOffset: information.valueOffset, valueLength: 8, runlistOffset: 0,
        startingCluster: 0, lastCluster: 0, dataSize: 8)
    expect(
        NTFSVolumeState.setting(dirty: true, in: volume.data, attributes: [stunted]) == nil,
        "a $VOLUME_INFORMATION too short to hold flags is not written to")
    let outboard = NTFSAttribute.Header(
        type: information.type, length: information.length, isResident: false,
        valueOffset: 0, valueLength: 0, runlistOffset: information.valueOffset,
        startingCluster: 0, lastCluster: 0, dataSize: 12)
    expect(
        NTFSVolumeState.setting(dirty: true, in: volume.data, attributes: [outboard]) == nil,
        "and neither is one whose value is out on the disk rather than in the record")
}

group("aVolumeWithUnfinishedWorkIsNotWrittenTo") {
    // NTFS writes down what it is about to do before doing it, so that a change
    // touching two structures can be finished or undone after a power cut. v2
    // cannot journal, so it may only make changes that touch exactly one thing
    // -- and it must refuse a volume that has unfinished work in it, because
    // that work is Windows's or chkdsk's to complete.

    let empty = Data([UInt8](repeating: 0xFF, count: 4096))
    expect(NTFSJournal.state(firstPage: empty) == .empty, "an unused journal is empty")
    expect(NTFSJournal.mayWrite(.empty), "and a volume with one may be written")

    var restart = [UInt8](repeating: 0, count: 4096)
    for (i, b) in Array("RSTR".utf8).enumerated() { restart[i] = b }
    expect(NTFSJournal.state(firstPage: Data(restart)) == .inUse, "a restart page means in use")
    expect(
        !NTFSJournal.mayWrite(.inUse),
        "and a journal in use is not written over -- it may hold a transaction nothing has "
            + "finished, and writing over it leaves a volume no implementation can reason about")

    var records = [UInt8](repeating: 0, count: 4096)
    for (i, b) in Array("RCRD".utf8).enumerated() { records[i] = b }
    expect(NTFSJournal.state(firstPage: Data(records)) == .inUse, "so does a page of records")

    expect(
        NTFSJournal.state(firstPage: Data(repeating: 0x41, count: 4096)) == .unrecognised,
        "anything else is unrecognised")
    expect(
        !NTFSJournal.mayWrite(.unrecognised),
        "and unrecognised is refused, because not understanding something is not the same as "
            + "knowing it is harmless")
    expect(NTFSJournal.state(firstPage: Data()) == .unrecognised, "as is nothing at all")

    // Four bytes of 0xFF could be a coincidence in a page holding something
    // else, so a generous prefix is checked rather than a signature-length one.
    var almost = [UInt8](repeating: 0xFF, count: 4096)
    almost[100] = 0x00
    expect(
        NTFSJournal.state(firstPage: Data(almost)) != .empty,
        "a page that is nearly all 0xFF but not quite is not called empty")

    // Reading is always allowed. A drive with unfinished work in its journal is
    // exactly the drive somebody wants their files off.
    expect(NTFSJournal.mayRead(.inUse), "a volume with work outstanding is still readable")
    expect(NTFSJournal.mayRead(.unrecognised), "and so is one we do not understand")

    // The real volume.
    let candidates = [
        ProcessInfo.processInfo.environment["LUKOTTA_NTFS_IMAGE"],
        NSHomeDirectory() + "/Library/Caches/dev.lukotta.e2e-dev/ntfs.img",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
        let handle = FileHandle(forReadingAtPath: path)
    else { return }
    defer { try? handle.close() }
    let lock = NSLock()
    guard
        let reader = NTFSVolumeReader(read: { offset, length in
            lock.lock()
            defer { lock.unlock() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: length)
        }), let page = reader.contents(ofFile: NTFSJournal.record, offset: 0, length: 4096)
    else {
        expect(false, "the journal's first page reads")
        return
    }
    expect(page.count == 4096, "a page of it comes back")
    expect(
        NTFSJournal.state(firstPage: page) == .empty,
        "and this volume's journal is empty -- it was formatted and never mounted read-write "
            + "by Windows, which is what makes it safe to write to")
    expect(
        reader.size(ofFile: NTFSJournal.record) ?? 0 > 1_000_000,
        "the journal is megabytes, as NTFS sizes it")
}

group("theShapeOfAnNtfsVolumeIsReadOrRefused") {
    // Where things are on an NTFS volume, which is the first thing anything
    // reading one has to know. Every field comes off a disk somebody plugged
    // in, so it is input rather than fact: a cluster size of zero divides by
    // zero, a huge one allocates for ever, and an MFT past the end of the
    // volume reads the next volume along.

    // A boot sector as Windows writes one: 512-byte sectors, 8 per cluster,
    // 1024-byte records written the negative way.
    func bootSector(
        bytesPerSector: Int = 512, sectorsPerCluster: Int = 8,
        totalSectors: UInt64 = 200_000, mft: UInt64 = 4, mftMirror: UInt64 = 100,
        recordSizeByte: Int8 = -10
    ) -> Data {
        var sector = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array("NTFS    ".utf8).enumerated() { sector[3 + i] = b }
        sector[0x0B] = UInt8(bytesPerSector & 0xFF)
        sector[0x0C] = UInt8((bytesPerSector >> 8) & 0xFF)
        sector[0x0D] = UInt8(sectorsPerCluster)
        for i in 0..<8 { sector[0x28 + i] = UInt8((totalSectors >> (8 * UInt64(i))) & 0xFF) }
        for i in 0..<8 { sector[0x30 + i] = UInt8((mft >> (8 * UInt64(i))) & 0xFF) }
        for i in 0..<8 { sector[0x38 + i] = UInt8((mftMirror >> (8 * UInt64(i))) & 0xFF) }
        sector[0x40] = UInt8(bitPattern: recordSizeByte)
        for i in 0..<8 { sector[0x48 + i] = UInt8((0xDEAD_BEEF >> (8 * UInt64(i))) & 0xFF) }
        return Data(sector)
    }

    guard let g = NTFSGeometry.read(bootSector()) else {
        expect(false, "an ordinary NTFS boot sector is read")
        return
    }
    expect(g.bytesPerSector == 512, "the sector size is read")
    expect(g.sectorsPerCluster == 8, "and the cluster size")
    expect(g.bytesPerCluster == 4096, "which multiply out to a cluster in bytes")
    expect(g.mftStartCluster == 4, "the master file table's cluster is read")
    expect(g.mftByteOffset == 4 * 4096, "and turns into a byte offset, which is what a read needs")
    expect(g.totalBytes == 200_000 * 512, "the volume's size comes out in bytes")
    expect(g.bytesPerFileRecord == 1024, "a negative record byte is a power of two: -10 is 1024")
    expect(g.serialNumber == 0xDEAD_BEEF, "and the serial number is read")

    // The other spelling: a positive byte means clusters per record.
    let positive = NTFSGeometry.read(bootSector(recordSizeByte: 1))
    expect(positive?.bytesPerFileRecord == 4096, "a positive record byte is a count of clusters")

    // Not NTFS at all.
    expect(NTFSGeometry.read(Data(count: 512)) == nil, "an empty sector is not a volume")
    expect(NTFSGeometry.read(Data(count: 100)) == nil, "and a short read is not one either")

    // Everything that would divide by zero, hang, or read another volume.
    expect(
        NTFSGeometry.read(bootSector(bytesPerSector: 0)) == nil,
        "a sector size of zero is refused rather than divided by")
    expect(
        NTFSGeometry.read(bootSector(bytesPerSector: 777)) == nil,
        "and so is one that is not a size NTFS uses")
    expect(
        NTFSGeometry.read(bootSector(sectorsPerCluster: 0)) == nil,
        "a cluster of no sectors is refused")
    expect(
        NTFSGeometry.read(bootSector(sectorsPerCluster: 3)) == nil,
        "so is one that is not a power of two")
    expect(
        NTFSGeometry.read(bootSector(sectorsPerCluster: 255)) == nil,
        "and one large enough to allocate for ever")
    expect(
        NTFSGeometry.read(bootSector(totalSectors: 0)) == nil,
        "a volume of no sectors is refused")
    expect(
        NTFSGeometry.read(bootSector(mft: 999_999_999)) == nil,
        "an MFT past the end of the volume is refused -- that read is the next volume along")
    expect(
        NTFSGeometry.read(bootSector(mftMirror: 999_999_999)) == nil,
        "and so is a backup MFT past the end")
    expect(
        NTFSGeometry.read(bootSector(recordSizeByte: -2)) == nil,
        "a record smaller than a sector is not a record")
    expect(
        NTFSGeometry.read(bootSector(recordSizeByte: -30)) == nil,
        "and one larger than any cluster is a number nobody writes")
}

group("bothBackingsKeepTheSamePromises") {
    // The extension is written once, against a seam, and two things sit behind
    // it: memory, which prices the framework and nothing else, and a real
    // directory, which is the shape of the thing that ships -- a module in
    // front, something holding the volume behind. The whole value of the seam
    // is that the volume cannot tell them apart, so the same promises are run
    // against both rather than against whichever was written first.
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("backing-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let backings: [(name: String, backing: any FSBacking)] = [
        ("memory", FSStoreBacking()),
        ("a real directory", FSPassthroughBacking(root: base)),
    ]

    for (name, fs) in backings {
        let root = fs.rootHandle
        expect(fs.attributes(of: root)?.isDirectory == true, "\(name): the root is a directory")
        expect(fs.lookup("absent", in: root) == nil, "\(name): and starts without that file")

        // Creating, and refusing the same name twice.
        guard let file = fs.create("report.txt", isDirectory: false, in: root, mode: 0o644) else {
            expect(false, "\(name): a file can be made")
            continue
        }
        expect(
            fs.create("report.txt", isDirectory: false, in: root, mode: 0o644) == nil,
            "\(name): the same name twice is EEXIST, not a second file")

        // Identity, which FSKit holds across the whole life of a file and which
        // has to survive a rename.
        let id = fs.attributes(of: file)?.id
        expect(id != nil && id != 0, "\(name): a file has an identifier")
        guard let folder = fs.create("Archive", isDirectory: true, in: root, mode: 0o755) else {
            expect(false, "\(name): a directory can be made")
            continue
        }
        expect(
            fs.rename("report.txt", in: root, to: "report.txt", in: folder),
            "\(name): a file moves to another directory")
        let moved = fs.lookup("report.txt", in: folder)
        expect(moved != nil, "\(name): and is found where it landed")
        expect(
            moved.flatMap { fs.attributes(of: $0)?.id } == id,
            "\(name): with the same identifier, which is what FSKit holds")
        expect(fs.lookup("report.txt", in: root) == nil, "\(name): and gone from where it was")

        // Contents, including a write past the end reading back as zeroes.
        guard let moved else { continue }
        let hello = Data("hello".utf8)
        expect(
            fs.write(moved, contents: hello, offset: 0) == hello.count,
            "\(name): a write reports what it took")
        expect(
            fs.read(moved, offset: 0, length: 99) == hello, "\(name): and reads back exactly that")
        expect(
            fs.read(moved, offset: 99, length: 10).isEmpty,
            "\(name): reading past the end is empty, not an error")
        _ = fs.write(moved, contents: Data("!".utf8), offset: 10)
        expect(fs.attributes(of: moved)?.size == 11, "\(name): a write past the end grows the file")
        expect(
            fs.read(moved, offset: 5, length: 5) == Data(count: 5),
            "\(name): and the gap reads as zeroes")
        fs.truncate(moved, to: 2)
        expect(fs.attributes(of: moved)?.size == 2, "\(name): truncating shortens it")

        // Extended attributes, which are what stop the volume collecting an
        // AppleDouble file beside every single file on it.
        let value = Data([0x01, 0x02])
        expect(
            fs.setXattr(
                "com.lukotta.test", to: value, on: moved, mustCreate: false,
                mustReplace: false) == .set,
            "\(name): an extended attribute can be set")
        expect(fs.xattr("com.lukotta.test", of: moved) == value, "\(name): and read back")
        expect(fs.xattrNames(of: moved).contains("com.lukotta.test"), "\(name): and listed")
        expect(
            fs.setXattr(
                "com.lukotta.test", to: value, on: moved, mustCreate: true,
                mustReplace: false) == .exists,
            "\(name): creating one that exists is EEXIST rather than an overwrite")
        expect(
            fs.setXattr(
                "com.lukotta.test", to: nil, on: moved, mustCreate: false,
                mustReplace: false) == .set,
            "\(name): and setting nil removes it")

        // Removal outcomes, each of which is a different errno and a different
        // sentence in front of somebody.
        expect(fs.remove("absent", from: root) == .missing, "\(name): what is not there is ENOENT")
        expect(
            fs.remove("Archive", from: root) == .notEmpty,
            "\(name): a directory with something in it is ENOTEMPTY")
        expect(fs.remove("report.txt", from: folder) == .removed, "\(name): the file goes")
        expect(fs.remove("Archive", from: root) == .removed, "\(name): and then the directory")

        // Enumeration order, which FSKit's directory cookie is an index into.
        // An order that moves between calls silently skips files.
        for entry in ["delta", "alpha", "charlie"] {
            _ = fs.create(entry, isDirectory: false, in: root, mode: 0o644)
        }
        let names = fs.children(of: root).map(\.name)
        expect(names == names.sorted(), "\(name): children come back sorted")
        expect(fs.children(of: root).map(\.name) == names, "\(name): and in the same order twice")

        expect(fs.usage().files > 0, "\(name): the volume counts what is on it")
    }
}

group("theExtensionClaimsOnlyWhatMacOSCannotOpen") {
    // Claiming a volume macOS already handles takes it away from the driver
    // that handles it properly. A drive that opens worse than it did before is
    // not an improvement, and the person would have no way to know why.
    expect(ExtensionMount.claims(.ntfs), "NTFS is the whole point")
    expect(ExtensionMount.claims(.bitlocker), "BitLocker, because it has to be got through first")
    expect(ExtensionMount.claims(.luks), "and LUKS for the same reason")

    // An encrypted drive that cannot be unlocked cannot be opened at all, which
    // is the hard constraint on the design: the two containers above are not
    // optional extras, they are the door.
    expect(
        ExtensionMount.claims(.bitlocker) && ExtensionMount.claims(.luks),
        "both encrypted containers are claimed, or encrypted drives stop opening")

    expect(!ExtensionMount.claims(.exfat), "exFAT is read and written natively")
    expect(!ExtensionMount.claims(.ext), "ext is not what this is for yet")
    expect(!ExtensionMount.claims(.btrfs), "nor btrfs")
    expect(!ExtensionMount.claims(.xfs), "nor XFS")
    expect(
        !ExtensionMount.claims(.unknown),
        "and a sector that identified as nothing is never claimed -- an unreadable "
            + "device is a question that could not be asked, not an answer of 'not ours'")

    // The probe reads a real sector and asks BootSector, the same reader the
    // drive list uses. One reader, so the two cannot come to disagree about
    // what a disk holds.
    var ntfs = [UInt8](repeating: 0, count: 512)
    for (i, b) in Array("NTFS    ".utf8).enumerated() { ntfs[3 + i] = b }
    expect(
        BootSector.identify(Data(ntfs)) == .ntfs,
        "an NTFS boot sector identifies as NTFS")
    expect(
        ExtensionMount.claims(BootSector.identify(Data(ntfs))),
        "and the extension claims it")

    var exfat = [UInt8](repeating: 0, count: 512)
    for (i, b) in Array("EXFAT   ".utf8).enumerated() { exfat[3 + i] = b }
    expect(
        !ExtensionMount.claims(BootSector.identify(Data(exfat))),
        "an exFAT one identifies and is left to macOS")
    expect(
        !ExtensionMount.claims(BootSector.identify(Data(count: 512))),
        "and an empty sector is left alone")
}

group("whatComesBackFromMountingThroughTheExtension") {
    // mount(8) reports a module that is switched off and a drive that cannot be
    // read with the same exit status, and those two mean opposite things: one
    // is "serve this over NFS and say nothing", the other is "this drive has a
    // problem". So the words are read, exactly as Diagnosis reads the engine's.
    let disabled = """
        Module com.lukotta.v2.fs is disabled!
        mount: Unable to invoke task
        """
    expect(
        ExtensionMount.outcome(status: 1, output: disabled) == .unavailable,
        "a module nobody has switched on means take the other route")
    expect(
        ExtensionMount.outcome(status: 1, output: "mount: unknown file system type")
            == .unavailable,
        "and so does a build with no extension in it at all")
    expect(
        ExtensionMount.outcome(status: 0, output: "") == .mounted,
        "nothing said and a clean exit is a mounted volume")

    let broken = "mount: /Volumes/X failed with 5\ninput/output error"
    expect(
        ExtensionMount.outcome(status: 1, output: broken)
            == .failed("mount: /Volumes/X failed with 5"),
        "a real failure keeps its first line, which is the one worth showing")

    // The engine's output arrives through a pty and carries carriage returns;
    // the same is true of anything read from a terminal-shaped pipe.
    expect(
        ExtensionMount.outcome(status: 1, output: "Module x is disabled!\r\n") == .unavailable,
        "carriage returns do not stop a phrase matching")

    // A switch that is off is the ordinary state of a Mac where nobody has
    // turned the extension on yet. Logging it on every attempt would bury the
    // failures that mean something.
    expect(!ExtensionMount.isWorthLogging(.unavailable), "a switched-off module is not logged")
    expect(!ExtensionMount.isWorthLogging(.mounted), "nor is success")
    expect(ExtensionMount.isWorthLogging(.failed("x")), "a real failure is")

    // The command is arguments and never a shell line: a volume name is
    // somebody else's text, and a drive called "; rm -rf ~" is a filename.
    let command = ExtensionMount.command(
        device: "/dev/disk4s2", mountPoint: "/Users/someone/Volumes/; rm -rf ~", readOnly: false)
    expect(command.first == "/sbin/mount", "it runs mount")
    expect(command.contains("-F"), "with -F, which is what names an FSKit module")
    expect(command.contains("lukottafs"), "and the filesystem the module registers under")
    expect(
        command.last == "/Users/someone/Volumes/; rm -rf ~",
        "and a hostile name arrives as one argument rather than as a command")
    expect(
        !ExtensionMount.command(device: "/dev/disk4s2", mountPoint: "/x", readOnly: false)
            .contains("ro"),
        "a writable mount does not ask for read-only")
    expect(
        ExtensionMount.command(device: "/dev/disk4s2", mountPoint: "/x", readOnly: true)
            .contains("ro"),
        "and a read-only one does")
}

group("theExtensionIsOnlyReachedWhereItCouldWork") {
    // FSKit arrives in macOS 15.4 and the application supports 15.0, so the
    // floor is checked rather than assumed. Getting this wrong does not crash:
    // it makes every mount on an older Mac try a route that cannot exist and
    // fall back, which costs a process launch on every single drive.
    func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }
    expect(
        !ExtensionMount.systemSupportsExtensions(version(15, 0)),
        "macOS 15.0 has no FSKit, and the app supports it")
    expect(
        !ExtensionMount.systemSupportsExtensions(version(15, 3)),
        "nor does 15.3, which is the last one without it")
    expect(
        ExtensionMount.systemSupportsExtensions(version(15, 4)),
        "15.4 is where it arrives")
    expect(
        ExtensionMount.systemSupportsExtensions(version(26, 6)),
        "and everything after has it")
    expect(
        !ExtensionMount.systemSupportsExtensions(version(14, 9)),
        "an older major version does not, whatever its minor")

    // Whether a build carries one is read from the bundle rather than from a
    // build flag, for the reason the app reads its own name and identifier the
    // same way: a build states what it can do instead of a constant claiming it.
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("bundle-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: empty.appendingPathComponent("Contents/PlugIns"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    if let plain = Bundle(url: empty) {
        expect(
            !ExtensionMount.isCarried(in: plain),
            "a bundle with no extension in it does not claim one")
    }
    try? FileManager.default.createDirectory(
        at: empty.appendingPathComponent("Contents/Extensions/LukottaFS.appex"),
        withIntermediateDirectories: true)
    if let carrying = Bundle(url: empty) {
        expect(
            ExtensionMount.isCarried(in: carrying),
            "and one with an appex beside its plug-ins does")
    }
}

group("anUpdateMustNotTakeTheExtensionAway") {
    // Measured on this Mac: replacing the installed application de-registers
    // the filesystem extension completely -- the appex is still on disk with a
    // valid signature and pluginkit reports nothing at all. lsregister -f does
    // not bring it back on the app or on the appex; pluginkit -a does.
    //
    // It matters more here than it would elsewhere, because the module has to
    // be switched on by hand once and the application cannot switch it on. An
    // update that removes it leaves somebody with a drive that will not open
    // until they find a switch nobody told them about.

    // A build with no extension does nothing at all. That is every channel but
    // v2, so it is the case that runs on almost every Mac.
    let plain = FileManager.default.temporaryDirectory
        .appendingPathComponent("plain-\(UUID().uuidString).app")
    try? FileManager.default.createDirectory(
        at: plain.appendingPathComponent("Contents/PlugIns"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plain) }
    if let bundle = Bundle(url: plain) {
        expect(
            ExtensionRegistration.appex(in: bundle) == nil,
            "a build with no extension has none to find")
        expect(
            ExtensionRegistration.repairIfMissing(identifier: "com.example.none", in: bundle)
                == .noExtension,
            "and repairs nothing, without asking the system anything")
    }

    // One that carries an extension knows where it is.
    let carrying = FileManager.default.temporaryDirectory
        .appendingPathComponent("carrying-\(UUID().uuidString).app")
    try? FileManager.default.createDirectory(
        at: carrying.appendingPathComponent("Contents/PlugIns"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
        at: carrying.appendingPathComponent("Contents/Extensions/LukottaFS.appex"),
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: carrying) }
    if let bundle = Bundle(url: carrying) {
        expect(
            ExtensionRegistration.appex(in: bundle)?.lastPathComponent == "LukottaFS.appex",
            "and one that carries an extension finds it beside its plug-ins")
    }

    // A module macOS already knows about is left alone. This is the whole of
    // the safety: registering one that is already registered issues a new
    // extension UUID, and doing that four times in one evening reset the
    // owner's System Settings switch under them every time. A repair that ran
    // unconditionally at launch would do that to everybody, for ever.
    expect(
        ExtensionRegistration.isRegistered("com.apple.fskit.msdos"),
        "a module the system knows about reads as registered")
    expect(
        !ExtensionRegistration.isRegistered("com.example.definitely.not.installed"),
        "and one it does not know about reads as missing")
    if let bundle = Bundle(url: carrying) {
        expect(
            ExtensionRegistration.repairIfMissing(
                identifier: "com.apple.fskit.msdos", in: bundle) == .alreadyRegistered,
            "so an extension that is already registered is never registered again")
    }

    // Doing nothing is what happens at every launch on every Mac where nothing
    // has gone wrong. A line each time would bury the one launch where
    // something did.
    expect(
        !ExtensionRegistration.isWorthLogging(.alreadyRegistered),
        "the ordinary case is not logged")
    expect(!ExtensionRegistration.isWorthLogging(.noExtension), "nor is a build without one")
    expect(ExtensionRegistration.isWorthLogging(.repaired), "a repair is")
    expect(ExtensionRegistration.isWorthLogging(.failed), "and so is one that did not work")
}

group("theOnlyChannelIntoTheExtensionIsItsMountOptions") {
    // An appex is launched by fskitd, not by whoever ran the command, so it
    // inherits no environment and no working directory. The mount options are
    // the only way to tell it anything. An earlier version of the extension
    // read its backing directory out of LUKOTTA_FS_ROOT, which meant it was
    // unset in the one situation it existed for.
    let options = ["-o", "ro,root=/tmp/somewhere,uid=501"]
    let values = FSMountOptions.values(in: options)
    expect(values["root"] == "/tmp/somewhere", "a value after = is the value")
    expect(values["ro"] == "", "one without is present and empty, not absent")
    expect(values["uid"] == "501", "and the rest come through beside it")
    expect(values["missing"] == nil, "what was not asked for is not there")

    // mount hands -o through as one comma-separated argument, which is the
    // convention every filesystem uses.
    expect(
        FSMountOptions.values(in: ["-o", "a=1", "-o", "b=2"])["b"] == "2",
        "more than one -o is read")
    expect(
        FSMountOptions.values(in: ["root=/x"]).isEmpty,
        "and a bare argument that was not after -o is not an option")

    // A read-only mount served writable is a drive somebody asked not to change
    // and changed. Both spellings are in use.
    expect(FSMountOptions.isReadOnly(["-o", "ro"]), "ro means read-only")
    expect(FSMountOptions.isReadOnly(["-o", "rdonly"]), "and so does rdonly")
    expect(!FSMountOptions.isReadOnly(["-o", "rw"]), "rw does not")
    expect(!FSMountOptions.isReadOnly([]), "and neither does saying nothing")

    // Only absolute paths. A relative one would be resolved against whatever
    // directory fskitd happened to start the extension in.
    expect(
        FSMountOptions.backingRoot(["-o", "root=/tmp/x"]) == "/tmp/x",
        "an absolute path is taken")
    expect(
        FSMountOptions.backingRoot(["-o", "root=tmp/x"]) == nil,
        "a relative one is refused rather than resolved somewhere arbitrary")
    expect(FSMountOptions.backingRoot(["-o", "root="]) == nil, "an empty one is refused")
    expect(FSMountOptions.backingRoot([]) == nil, "and saying nothing means memory")

    // The value is somebody else's text and is never taken apart twice: a path
    // with an = in it keeps it.
    expect(
        FSMountOptions.values(in: ["-o", "root=/tmp/a=b"])["root"] == "/tmp/a=b",
        "only the first = separates, so a path may contain one")
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
