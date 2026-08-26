# Plan

**[you]** marks what needs credentials, a decision or hardware only you have.

- [ ] Cover the privileged route with a test. Nothing does: every fixture is a
  container file, and those open without a password, so the deadline the daemon
  keeps, the mount root it clears and the unmount it lends the sweep are never
  reached.
- [ ] Draw the unlock sheet and the screen shown while a drive is opening.
  `scripts/screenshots.sh` draws the drive list only, and the site wants three.
- [ ] **[you]** Name `preflight.sh` in CONTRIBUTING, which lists three tests
  and not the one a release has to pass.
- [ ] **[you]** Put the other two screens in the README, whose pictures are the
  drive list only.
- [ ] **[you]** Push the `beta/` directory to the appcast repository, so the
  pre-release feed answers at `updates.lukotta.com/beta/appcast.xml`.
- [ ] **[you]** Push `clementrahula/homebrew-tap`, so `lukotta` and
  `lukotta@beta` install.
- [ ] Re-test FSKit on the current macOS. Third-party extensions were broken on
  26.1 and 26.2 — `fskitd` rejects unprivileged clients, which breaks Apple's
  own sample. One afternoon, and it decides whether the route is open.
- [ ] Test whether Apple's read-only NTFS kext probes a *locked* BitLocker
  partition. It holds FVE metadata rather than an NTFS boot sector, so it may
  not — which would sidestep module masking entirely.
- [ ] Prototype BitLocker unlock with `libbde` (LGPL-3.0). Useful whichever
  route is taken.
- [ ] Choose between FSKit with our own NTFS implementation and DriverKit with
  a licensed driver. DriverKit block-storage entitlements need Apple's
  approval, so that conversation starts early. NTFS read and write dominates
  the cost either way.
