// Unit tests for the pure logic in Lukotta.
// Built and run by tests/run-swift-tests.sh — no Xcode project required.
import Foundation

var failures = 0
var checks = 0

func expect(_ actual: String, _ expected: String, _ what: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(what)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("FAIL: \(what)") }
}

// MARK: quoting — these build a command that runs as root, so they matter

expect(shellQuoted("/dev/disk4s1"), "'/dev/disk4s1'", "plain path quoting")
expect(shellQuoted("/Volumes/My Drive"), "'/Volumes/My Drive'", "spaces survive quoting")
expect(shellQuoted("it's"), #"'it'\''s'"#, "single quote is escaped")
expect(shellQuoted("a; rm -rf /"), "'a; rm -rf /'", "shell metacharacters are neutralised")

expect(appleScriptQuoted("plain"), "\"plain\"", "applescript plain")
expect(appleScriptQuoted("say \"hi\""), "\"say \\\"hi\\\"\"", "applescript escapes quotes")
expect(appleScriptQuoted("back\\slash"), "\"back\\\\slash\"", "applescript escapes backslash")

// MARK: recovery-key hinting

expect(Credential.hint(for: "") == nil, "empty input gives no hint")
expect(Credential.hint(for: "hunter2") == nil, "a password gives no recovery-key hint")
expect(Credential.hint(for: "121121-131131-141141-151151-161161-171171-181181-191191")
        == "Recovery key — 48 digits", "complete recovery key is recognised")
expect(Credential.hint(for: "121121-131131-141141-151151")?.contains("24 of 48") == true,
       "partial recovery key reports progress")
expect(Credential.hint(for: "1234") == nil, "short numeric input is treated as a password")

// MARK: engine status parsing

let statusSample = """
/dev/disk4s1 on /Volumes/BACKUP (ntfs3, iocharset=utf8, uid=501, gid=20, mounted by someone) VM[cpus: 4, ram: 2048 MiB]
"""
let parsed = EngineStatus.parse(statusSample)
expect(parsed.count == 1, "one mount parsed")
expect(parsed.first?.devicePath ?? "", "/dev/disk4s1", "device parsed")
expect(parsed.first?.mountPoint ?? "", "/Volumes/BACKUP", "mount point parsed")

let spacey = "/dev/disk9s2 on /Volumes/My Backup Drive (ntfs3, mounted by someone) VM[cpus: 2]"
expect(EngineStatus.parse(spacey).first?.mountPoint ?? "", "/Volumes/My Backup Drive",
       "mount point with spaces parsed")
expect(EngineStatus.parse("").isEmpty, "empty status yields no mounts")
expect(EngineStatus.parse("garbage line without markers").isEmpty, "unparseable line ignored")

// MARK: failure diagnosis

expect(Diagnosis.summarise("cryptsetup: No key available with this passphrase.", fallback: ""),
       "That password or recovery key did not unlock this drive.", "wrong key diagnosis")
expect(Diagnosis.summarise("macOS: Error: Cannot probe /dev/disk4s1: LibErr(0); Insufficient permissions?",
                           fallback: "").contains("Full Disk Access"),
       "TCC refusal diagnosis")
expect(Diagnosis.summarise("error: device is already mounted", fallback: "").contains("already"),
       "already-mounted diagnosis")
expect(Diagnosis.summarise("", fallback: "").isEmpty == false, "empty transcript still yields a sentence")

// MARK: volume kinds and the dirty-volume path

expect(VolumeKind.microsoft.summary, "BitLocker or NTFS", "microsoft kind summary")
expect(VolumeKind.linux.summary, "LUKS or Linux filesystem", "linux kind summary")

let d = Drive(id: "disk4s1", devicePath: "/dev/disk4s1", name: "BACKUP",
              sizeBytes: 500_000_000_000, connection: "USB · External", kind: .microsoft)
expect(d.subtitle.contains("BitLocker or NTFS"), "subtitle states what the volume might be")
expect(d.subtitle.contains("disk4s1"), "subtitle keeps the device identifier")

// Windows Fast Startup and hibernation are the most common real-world failure,
// and the advice has to be actionable rather than a raw driver error.
let dirty = Diagnosis.summarise("ntfs3: volume is dirty and mounting is refused", fallback: "")
expect(dirty.contains("Fast Startup"), "dirty volume explains Fast Startup")
let hib = Diagnosis.summarise("Windows is hibernated, refused to mount (hiberfile)", fallback: "")
expect(hib.contains("Fast Startup"), "hibernated volume gets the same advice")
expect(Diagnosis.summarise("mount: unknown filesystem type 'crypto_LUKS'", fallback: "")
        .contains("did not recognise"), "unrecognised filesystem diagnosis")

// MARK: LVM discovery — fixture captured from a real LUKS2+LVM+btrfs volume

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
expect(lvs.first?.identifier ?? "", "lukottavg:luks-lvm.img:data", "vg:disk:lv identifier parsed")
expect(lvs.first?.mountIdentifier ?? "", "lvm:lukottavg:luks-lvm.img:data", "mount identifier built")
expect(lvs.first?.filesystem ?? "", "btrfs", "filesystem parsed")
expect(lvs.first?.label ?? "", "LUKOTTATEST", "filesystem label parsed")
expect(VolumeGroupParser.logicalVolumes(in: "").isEmpty, "no volume groups in empty output")
expect(VolumeGroupParser.logicalVolumes(in: "   1:  crypto_LUKS  x  1 GB  a:b:c").isEmpty,
       "container types are not offered as mountable")

expect(Permissions.isAccessDenied("Cannot probe /dev/disk4s1"), "access denial detected")
expect(!Permissions.isAccessDenied("No key available"), "wrong key is not an access denial")

// MARK: result

print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED: \(failures) check(s)")
    exit(1)
}
print("PASS: Lukotta unit tests")
