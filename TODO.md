# Plan

What is left to do. **[you]** marks what needs credentials, a decision or
hardware only you have.

---

## Stage 1 — the first release

- [ ] **A test that reaches the privileged route.** Every fixture here is a
  container file, and a container file opens without a password — so nothing
  in the harnesses has ever been through the daemon or an administrator
  prompt. The deadline the daemon keeps, the mount root it clears and the
  unmount it lends the sweep are reachable no other way. Two faults shipped
  through it in one night, and a person found both. AGENTS.md lists the gap
  under what has never run against a real disk.
- [ ] **Pictures of the unlock sheet and the opening screen.**
  `./scripts/screenshots.sh` draws the drive list in every language and both
  appearances. The site wants the other two screens as well.
- [ ] **[you] The documents that are yours.** README.md, CONTRIBUTING.md and
  the legal files have been left alone throughout. Two things in them are
  behind: CONTRIBUTING names three tests and there are four, the fourth being
  `preflight.sh`, which is what a release has to pass; and the README's
  screenshots are the drive list only.
- [ ] **[you] Publish the feed and the casks.** Neither has been pushed. The
  appcast repository serves `updates.lukotta.com`, with the pre-release feed a
  `beta/` directory inside it; the first beta release writes it. The tap,
  `clementrahula/homebrew-tap`, carries `lukotta` and `lukotta@beta`, both
  written by `release.sh` from the disk image it uploaded. Nothing is
  installable until both are pushed and the repository is public.

## Stage 2 — larger bets

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
