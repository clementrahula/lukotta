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

## Deleting over NFS is slow, and the fix is not on the NFS side

Deleting a photo library from a mounted drive takes minutes, one unlink per
file, and Finder's move-to-Trash fails outright ("some items had to be
skipped") because the volume has no usable `.Trashes`.

Measured on a 40 GB NTFS volume, 6000 small files:

    over NFS, 2 nfsd threads    5000 ms
    over NFS, 8 nfsd threads    4172 ms   (reverted; 20% is not a fix)
    over NFS, async export      4550 ms   (no help; the guest is not the wait)
    inside the guest               0 ms

The whole cost is the NFS round trip per unlink. Nothing tuned on the server
side moves it, because the server is not what is waiting.

So a delete has to run in the guest rather than travel over NFS. The guest
already runs commands for us -- that is how multi-volume mounts are served --
so the mechanism exists. What does not exist is a route from Finder's delete to
the guest: Finder issues the unlinks itself and Lukotta never sees them.

Two shapes worth considering, neither started:

- A Finder Sync extension offering "Delete with Lukotta" on volumes we serve,
  which hands the paths to the guest and runs one `rm -rf` there.
- Lukotta doing deletion in its own window, for people who would rather not
  install an extension.

Creating `.Trashes` on the drive was considered and rejected: it makes Finder's
delete instant by turning it into a rename, but it writes to a drive we opened,
which is a thing this application does not do.
