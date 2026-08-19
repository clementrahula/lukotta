// Unit tests for the pure logic in FULocker.
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

expect(Permissions.isAccessDenied("Cannot probe /dev/disk4s1"), "access denial detected")
expect(!Permissions.isAccessDenied("No key available"), "wrong key is not an access denial")

// MARK: result

print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED: \(failures) check(s)")
    exit(1)
}
print("PASS: FULocker unit tests")
