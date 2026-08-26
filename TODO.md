# Plan

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
