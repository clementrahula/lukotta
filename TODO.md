# Plan

What is left to do. **[you]** marks what needs credentials, a decision or
hardware only you have.

---

## Stage 1 — the first release

- [ ] **[you] The hardware pass.** A BitLocker drive, to prove the
  first-sector probe recognises one before a password is typed, and one unlock
  of a physical drive through the helper. Both need a drive at your keyboard;
  everything reachable with images is already covered end to end.
- [ ] **Pictures of the unlock screen.** `./scripts/screenshots.sh` draws the
  drive list in every language and both appearances; the unlock sheet and the
  screen shown while a drive is opening are not among them, and the site wants
  all three.

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

NTFS read/write dominates the cost either way.
