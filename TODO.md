# Plan

What is left to do. **[you]** marks what needs credentials, a decision or
hardware only you have.

---

## Stage 1 — the first release

- [ ] **[you] The hardware pass.** A BitLocker drive, to prove the
  first-sector probe recognises one before a password is typed, and one unlock
  of a physical drive through the helper. Both need a drive at your keyboard;
  everything reachable with images is already covered end to end.

  It has grown a little since: the privileged route is now the only one whose
  deadline, whose cleanup of a mount root left behind, and whose daemon-lent
  unmount have never run against a real disk. Every fixture here is a container
  file, which opens without a password, so none of that is reached. AGENTS.md
  lists it under what has never run against a real disk.
- [ ] **Pictures of the unlock screen.** `./scripts/screenshots.sh` draws the
  drive list in every language and both appearances; the unlock sheet and the
  screen shown while a drive is opening are not among them, and the site wants
  all three.
- [ ] **[you] The documents that are yours.** README.md, CONTRIBUTING.md and the
  legal files were left alone through two nights of changes. Three things in
  them may now be worth a look: CONTRIBUTING describes the tests as
  `run-tests.sh`, `lint.sh` and `e2e.sh`, and there is a third now —
  `preflight.sh`, which is what a release has to pass; the README's Download
  button points at `releases/latest/download/Lukotta.dmg`, which resolves from
  the first release that uploads one; and the README's screenshots are the
  drive list only, while `scripts/screenshots.sh` can now draw it in every
  language and both appearances.
- [ ] **[you] The pre-release feed's directory.** The appcast repository serves
  `updates.lukotta.com`; the beta feed is a `beta/` directory in the same
  repository now, rather than a second domain. The first beta release writes it:
  `LUKOTTA_CHANNEL=beta LUKOTTA_APPCAST=../lukotta-appcast/beta/appcast.xml`.

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
