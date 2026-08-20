import Foundation

/// Turns raw engine output into one plain sentence, without hiding the original.
public enum Diagnosis {
    public static func summarise(_ transcript: String, fallback: String) -> String {
        let lower = transcript.lowercased()
        if lower.contains("cannot probe") || lower.contains("insufficient permissions") {
            return
                "macOS blocked access to the drive. Lukotta needs Full Disk Access before it can read an encrypted disk."
        }
        if lower.contains("wrong key") || lower.contains("invalid passphrase")
            || lower.contains("no key available") || lower.contains("keyslot")
        {
            return "That password or recovery key did not unlock this drive."
        }
        if lower.contains("not a valid bitlocker") || lower.contains("no bitlocker") {
            return "This partition is not a BitLocker volume."
        }
        if lower.contains("hiberfile") || lower.contains("hibernated")
            || lower.contains("unclean") || lower.contains("dirty")
        {
            return
                "The drive was not shut down cleanly by Windows. Turn off Fast Startup in Windows, or shut Windows down fully rather than hibernating, then try again."
        }
        if lower.contains("unknown filesystem type") || lower.contains("no such device") {
            return
                "The engine did not recognise a filesystem on this volume. If it is encrypted, the password or recovery key may be wrong."
        }
        if lower.contains("already mounted") {
            return "macOS already has this drive mounted. Eject it in Finder and try again."
        }
        if lower.contains("hypervisor") || lower.contains("hv_") || lower.contains("vmm") {
            return "The virtualisation engine could not start. A restart usually clears this."
        }
        if lower.contains("resource busy") || lower.contains("device busy") {
            return "The drive is busy. Close anything using it, then try again."
        }
        // Prefer the engine's last meaningful line over a generic message.
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last, last.count > 8 { return last }
        let fb = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fb.isEmpty ? "The drive could not be opened." : fb
    }
}
