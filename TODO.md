# Plan

What is left to do. **[you]** marks what needs credentials, a decision or
hardware only you have.

---

## Next

- [ ] **[you] The DNS record for updates-beta.lukotta.com.** Everything else on
  the beta channel is built and proved: its own icon, its own appcast path in
  `release.sh`, and a real beta-to-beta update applied against a local feed.
  `scripts/update-test.sh` runs the whole thing.

---

## Stage 1 — the first release

- [ ] **[you] The hardware pass.** A BitLocker drive, to prove the
  first-sector probe recognises one before a password is typed, and one unlock
  of a physical drive through the helper. Both need a drive at your keyboard;
  everything reachable with images is already covered end to end.
- [ ] **[you] Screenshots** — the drive list, an unlock, a drive open with
  several volumes, in both appearances. The README, the site and every listing
  in Stage 2 want them.

## Stage 3 — larger bets

### A native volume instead of a network share

The single biggest difference from the paid alternatives, and only replacing the
transport fixes it.

- [ ] Re-test FSKit on the current macOS. Third-party extensions were broken on
  26.1 and 26.2 — `fskitd` rejects unprivileged clients, which breaks Apple's own
  sample. One afternoon, and it decides whether the route is open.
- [ ] Test whether Apple's read-only NTFS kext probes a *locked* BitLocker
  partition. It holds FVE metadata rather than an NTFS boot sector, so it may
  not — which would sidestep module masking entirely.
- [ ] Prototype BitLocker unlock with `libbde` (LGPL-3.0). Useful under every
  route.
- [ ] Then choose: FSKit with our own NTFS implementation, or DriverKit with a
  licensed driver. DriverKit block-storage entitlements need Apple's approval, so
  that conversation starts early.

NTFS read/write dominates the cost either way. Going native also removes the GPL
constraint, so this and a proprietary product are the same project.

---

## Untried

- **The plain-NTFS path.** The first-sector probe recognises three formats and
  there is no unencrypted NTFS drive to hand, so the note saying a drive is not
  encrypted, and opening one with no password, have never run against a real
  disk. Identification is covered both ways by tests over synthetic boot sectors,
  and anything unrecognised is left alone.

## Known limitations

Properties of the design, not tasks.

- **Encryption nested inside encryption is not opened.** A logical volume that is
  itself a LUKS container fails and the drive falls back to a single volume. It
  should say so rather than look broken. Several containers on one disk are fine.
- **The initialise dialog is only held back while Lukotta is running.** Claiming
  the disk suppresses it, and a claim belongs to a running process.
- **The volume appears as a network drive.** macOS offers no supported way to
  mark an NFS mount local. Only Stage 3 changes it.
- **Full Disk Access cannot be requested.** No API exists; the app detects the
  refusal and explains it.
- **The drive's name in Finder is right from the second unlock onward.** The
  label is not knowable until the volume is open, which is after the share is
  named.
- **A crash with a fallback mount open produces the system's "server connections
  interrupted" dialog.** The crash cannot be intercepted, only avoided by
  unmounting first.
- **Apple Silicon, macOS 15 or later, no Mac App Store.** Sandboxed apps cannot
  read raw devices or elevate.
- **TPM-sealed volumes and detached LUKS headers cannot be opened.**
