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

## Who does what

Documentation and user-interface work happen only with the owner watching, when
the owner asks for them. That covers the README, the website, the About page,
the first-launch consent screen, and anything else that changes what a person
reads or clicks. They are written below so they are not forgotten, not so they
are picked up.

Everything else -- formats, filesystems, bugs, the engine, the guest, the test
harnesses -- is fair game to fix without asking.

Dependencies, patches, kernel modules and libraries may be added where they
fill a real gap, and a tested thing from upstream beats a bespoke one. The
licence is checked every time, before it goes in: this app is GPL-3.0-or-later,
the guest aggregates GPL-2 and compatible userspace, and nothing gets linked
into the app that cannot be. Whatever is added is recorded with its licence in
the SBOM and the notices.

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

## Open what the engine can open, and re-decide what we excluded

The engine reaches more filesystems than this app offers, and the gap was never
a decision so much as an accumulation. Worth going through deliberately.

- [ ] **RAID is claimed and cannot be opened.** `DiskWatcher.ourContent`
  includes the Linux RAID type GUID `A19D880F-05FC-4D3B-A006-743F0F84911E`, so
  the app claims those disks and macOS stops offering to initialise them. But
  `mdadm` is on `trim-image.py`'s drop list and is not in the shipped guest,
  and nothing in the app ever builds the `raid:` identifier the engine wants --
  `EngineStatus` only recognises one in the mount table. So somebody who plugs
  in a RAID member gets a disk that appears, is protected from being
  initialised, and cannot be opened, with nothing saying why. Either carry
  mdadm and mount it, or stop claiming the type. Claiming and refusing is the
  one combination that helps nobody. mdadm is kept as of trim-image.py's roots;
  what is left is the app side.

  Read out of the engine rather than guessed at: `assemble_raid` is set only on
  the `raid:` and `lvm:` branches of `cmd_mount.rs`. The plain multi-disk
  branch never sets it, so handing it `/dev/diskXsY` for a member does not
  assemble anything -- the app has to build `raid:<devA>[:<devB>...]` itself,
  and the assembled array appears inside the guest as `/dev/md127`.

  Which means the app needs to group members into arrays before it can name
  one. `VolumeGroupParser.containers` already recognises `linux_raid_member`
  and skips it, so the place to start is there rather than from nothing.
- [ ] **Re-decide ZFS.** `trim-image.py` drops `zfs` and `zfs-libs`, but the
  guest still ships the kernel modules -- `lib/modules/6.12.62/fs/zfs/zfs.ko`
  and `spl.ko` are in the packed rootfs right now. So we carry the weight and
  not the capability. The re-decision has a licence dimension as well as a size
  one: ZFS is CDDL, which is the long-running incompatibility with a GPL-2
  kernel, and this app is GPL-3-or-later distributing that guest. Decide it on
  purpose and write the reason down, whichever way it goes.
- [ ] Go through the rest the same way: F2FS, squashfs (`squashfs-tools` is
  also dropped), UDF, and the FreeBSD image the engine can boot for UFS. For
  each: does the guest kernel have the driver, does the guest have the tools,
  does the app offer it, and does `DiskWatcher` claim the type. Those four
  should agree.

## Re-test every format we claim, properly, read and write

The formats were added at different times and tested to different depths. XFS
sat in the advertised list for months with a stub file standing in for a
fixture and nothing had ever opened one. That is unlikely to be the only such
gap.

- [ ] Run the full corpus at each: `copy-torture.sh` for byte-identical read
  and write across the awkward shapes, `integrity-vectors.sh` for the crash and
  concurrency cases, `xattr-forks.sh` for what macOS attaches to a file. Every
  advertised format, both directions, results written into
  `make-format-volumes.sh` beside the ones already there.
- [ ] While doing it, look upstream before hand-rolling. `ntfsprogs-plus`
  already provides `ntfsck`, which repairs structural damage our ladder can
  currently only refuse. The engine's own test suite (`tests/*.bats`) covers
  cases we re-derived by hand. Borrowing a maintained implementation beats
  another bespoke one that only this project ever exercises.
