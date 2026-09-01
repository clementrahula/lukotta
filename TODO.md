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

## Say what this is built on, what was wrong, and how anyone can check

The README barely names anylinuxfs, which is the thing doing the mounting. That
is both ungenerous and unhelpful: somebody deciding whether to trust this app
cannot see what it is made of, and somebody debugging it cannot see where the
layers meet.

- [ ] Credit anylinuxfs properly in the README and say what it does, what
  Lukotta adds on top, and where the boundary is. `upstream-notes.md` already
  has the technical half of this.
- [ ] Write down what was actually wrong and what fixed it. The copy that died
  at 84% with error 100060 was a `timeo` that did nothing because `dumbtimer`
  was absent; the fix is one mount option and the evidence is two complete
  13 GB copies with every file byte-identical. That story is worth telling,
  because "we fixed some bugs" is worth nothing.
- [ ] And say how to check it rather than asking to be believed. The scripts
  are already in `scripts/` -- copy-torture, integrity-vectors, corrupt-corpus,
  xattr-forks, lvm-lock-rule, eight-gig-pressure -- and each prints numbers.
  A short section naming which script proves which claim.

## Tell people, once, that this is new

- [ ] A first-launch screen with a consent button saying plainly that the app
  is young and largely experimental, with concrete examples rather than a
  disclaimer nobody reads: reading a drive is safe; copying off it is safe;
  writing to a drive whose only copy of something matters is where the risk
  is; a volume Windows left dirty is repaired rather than refused, and that is
  a deliberate choice with a real consequence.

  This is one screen, once, before anything is opened -- not a prompt in the
  copy path. The rule that there is no new click during a copy is untouched by
  it. Somebody agreeing to try an experimental thing is entitled to know that
  is what they are doing.

## The website is too shallow to be trusted

- [ ] `lukotta-website` should name anylinuxfs and say what the architecture
  actually is -- a microVM per volume, the Linux drivers doing the reading,
  NFS carrying it back to Finder. People evaluating a disk tool want to know
  what touches their disk.
- [ ] Make it more technical throughout. The audience for a tool that mounts
  BitLocker and LUKS on a Mac already knows what those words mean.
- [ ] Rewrite the About page. It says very little and none of it is specific.
