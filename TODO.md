# Plan

- [ ] Re-test FSKit on the current macOS. Third-party extensions were broken on
  26.1 and 26.2: `fskitd` rejects unprivileged clients, which breaks Apple's own
  sample. One afternoon, and it decides whether the route is open.
- [ ] Test whether Apple's read-only NTFS kext probes a *locked* BitLocker
  partition. It holds FVE metadata, not an NTFS boot sector, so it may not,
  which would sidestep module masking entirely.
- [ ] Prototype BitLocker unlock with `libbde` (LGPL-3.0). Useful whichever
  route is taken.
- [ ] Choose between FSKit with our own NTFS implementation and DriverKit with
  a licensed driver. DriverKit block-storage entitlements need Apple's
  approval, so that conversation starts early. NTFS read and write dominates
  the cost either way.

## Deleting over NFS is slow, and the fix is not on the NFS side

Deleting a photo library takes minutes, one unlink per file, and Finder's
move-to-Trash fails outright ("some items had to be skipped") because the volume
has no usable `.Trashes`.

Measured on a 40 GB NTFS volume, 6000 small files:

    over NFS, 2 nfsd threads    5000 ms
    over NFS, 8 nfsd threads    4172 ms   (reverted; 20% is not a fix)
    over NFS, async export      4550 ms   (no help; the guest is not the wait)
    inside the guest               0 ms

The cost is the NFS round trip per unlink, and nothing tuned server-side moves
it. So a delete has to run in the guest. The guest already runs commands for
us, which is how multi-volume mounts are served. What is missing is a route
from Finder's delete to the guest: Finder issues the unlinks itself and Lukotta
never sees them.

Neither of these is started:

- A Finder Sync extension offering "Delete with Lukotta" on volumes we serve,
  handing the paths to the guest for one `rm -rf`.
- Lukotta deleting in its own window, for people who would rather not install
  an extension.

Creating `.Trashes` on the drive was rejected. It makes Finder's delete instant
by turning it into a rename, and it writes to a drive we opened.

## fsync does not survive a killed machine

- [x] **Cause found, 2026-09-02.** Nothing in the stack ever flushed the drive.
  Measured on macOS 26, on a target opened for writing:

      target         fsync   F_FULLFSYNC   DKIOCSYNCHRONIZECACHE
      device node    ok      ENOTTY        ok
      regular file   ok      ok            ENOTTY

  The two calls are exact complements, and the first column is the trap:
  `fsync` on a device node returns success having done nothing. imago's
  `sync()` offered only those two, `fsync` under libkrun's `relaxed_sync`
  (which macOS gets unconditionally, `libkrun-1.19.3/src/lib.rs:789`) and
  `F_FULLFSYNC` otherwise, which a device refuses. So a raw device could not be
  flushed by either branch, and both reported that it had been.

  That is also why the earlier readings looked like a filesystem difference. An
  image handed to the engine is a regular file, where `fsync` is real, and it
  survived byte-identical; the same bytes on a physical drive vanished.

  `patches/imago-flush-device-nodes.patch` adds the device branch, decided at
  open rather than stat-ed on every barrier, tolerating a device that answers
  that it has no cache to flush. Without that tolerance every barrier becomes
  an I/O error and nothing mounts.

- [x] **The mechanism is proven.** The patch carries an example that opens a
  device node and calls imago's own `sync()`. On the same attached device:
  unpatched gives `Inappropriate ioctl for device (os error 25)`, patched gives
  `sync ok`. So the flush is issued and the device performs it.

- [ ] **Durability across a kill is not.** Only a physical drive reproduces the
  loss: against an unpatched engine, `kill-durability.sh` on an attached image
  returned the 8 MB byte-identical, because those writes reach the backing file
  through the host's buffer cache, which a killed guest does not discard. The
  run on the one physical drive here needs that drive's engine killed, which is
  somebody's only backup.

  Timing it instead did not work: 121.5 ms median unpatched against 117.0 ms
  patched over twenty 1 MiB writes, which is noise, and smaller writes are
  dominated by the NFS round trip. `scripts/flush-reaches-drive.sh` carries the
  numbers so it is not tried again.

- [ ] **Then measure what it costs.** `DKIOCSYNCHRONIZECACHE` on every guest
  barrier may undo the copy-time win from `wsize=32768` (worst case 90.05 s to
  16.56 s). If it does, the ioctl narrows to the paths that need it.

Ruled out along the way, each by measurement: the host block cache, the guest
export (vmproxy builds `{rw|ro},no_subtree_check,no_root_squash,insecure` with
no `async`, so nfsd commits before answering), the guest mount options
(`dirsync` changed nothing and cost every many-small-file copy something, so it
was reverted), export write gathering (`no_wdelay`), and ntfs3 itself.

SIGTERM is clean: 100 MB survives and the machine exits in 0.34 s, which is why
`EngineProcesses.flushGrace` waits twenty seconds for it. What was exposed is a
force quit, a crash, or the power going.

## The app cannot open a volume group from an image file

- [ ] `scripts/e2e.sh` fails one step of 851, and it is neither a flake nor a
  timeout. A LUKS container holding an LVM volume group fails the first check
  after scanning, `imageOpening == nil && phaseIsUnlock`, and raising the
  allowance from 60 s to 140 s changed nothing. A qcow2 immediately above it in
  the same run passes the same check.

  The engine route works: `--drive open` on the same file takes 67.7 s and
  mounts everything at /Volumes/LUKOTTATEST. So the fault is in the app's
  `openImage` path. A volume group has something to decide that a plain
  filesystem does not, which volume, so it may land in a phase the test does
  not expect. Either the app takes a different route for a volume group or the
  test expects the wrong one.

  The same layout works through the drive route, which is how anybody with a
  real Linux disk arrives. This is the image-file route: opening a `.img` of a
  Linux laptop disk.

## Who does what

Documentation and user-interface work happen only with the owner watching, when
the owner asks. That covers the README, the website, the About page, the
first-launch consent screen, and anything else that changes what a person reads
or clicks. They are written below so they are not forgotten.

Everything else, formats and filesystems and bugs and the engine and the guest
and the test harnesses, is fair game to fix without asking.

Dependencies, patches, kernel modules and libraries may be added where they
fill a real gap, and a tested thing from upstream beats a bespoke one. The
licence is checked every time, before it goes in: this app is GPL-3.0-or-later,
the guest aggregates GPL-2 and compatible userspace, and nothing gets linked
into the app that cannot be. Whatever is added is recorded with its licence in
the SBOM and the notices.

## Say what this is built on, what was wrong, and how anyone can check

- [ ] Credit anylinuxfs properly in the README: what it does, what Lukotta adds,
  where the boundary is. `upstream-notes.md` has the technical half.
- [ ] Write down what was wrong and what fixed it. The copy that died at 84%
  with error 100060 was a `timeo` that did nothing because `dumbtimer` was
  absent. The fix is one mount option and the evidence is two complete 13 GB
  copies with every file byte-identical.
- [ ] Say how to check it. The scripts are in `scripts/`: copy-torture,
  integrity-vectors, corrupt-corpus, xattr-forks, lvm-lock-rule,
  eight-gig-pressure, kill-durability. Each prints numbers. A short section
  naming which script proves which claim.

## Tell people, once, that this is new

- [ ] A first-launch screen with a consent button, with concrete examples rather
  than a disclaimer nobody reads: reading a drive is safe; copying off it is
  safe; writing to a drive whose only copy of something matters is where the
  risk is; a volume Windows left dirty is repaired, which is a deliberate
  choice with a real consequence.

  One screen, once, before anything is opened. Not a prompt in the copy path;
  the rule that there is no new click during a copy is untouched.

## The website is too shallow to be trusted

- [ ] `lukotta-website` should name anylinuxfs and say what the architecture is:
  a microVM per volume, the Linux drivers doing the reading, NFS carrying it
  back to Finder.
- [ ] Make it more technical throughout. The audience for a tool that mounts
  BitLocker and LUKS on a Mac already knows what those words mean.
- [ ] Rewrite the About page. It says little and none of it is specific.

## Open what the engine can open, and re-decide what we excluded

The engine reaches more filesystems than this app offers, and the gap
accumulated rather than being decided.

- [ ] **RAID is claimed and cannot be opened.** `DiskWatcher.ourContent`
  includes the Linux RAID type GUID `A19D880F-05FC-4D3B-A006-743F0F84911E`, so
  the app claims those disks and macOS stops offering to initialise them.
  Nothing in the app builds the `raid:` identifier the engine wants;
  `EngineStatus` only recognises one already in the mount table. So somebody
  plugging in a RAID member gets a disk that appears, is protected from being
  initialised, and cannot be opened, with nothing saying why.

  Read out of the engine rather than guessed: `assemble_raid` is set only on
  the `raid:` and `lvm:` branches of `cmd_mount.rs`. The plain multi-disk
  branch never sets it, so handing it `/dev/diskXsY` for a member assembles
  nothing. The app has to build `raid:<devA>[:<devB>...]` itself, and the
  assembled array appears inside the guest as `/dev/md127`.

  So the app needs to group members into arrays before it can name one.
  `VolumeGroupParser.containers` already recognises `linux_raid_member` and
  skips it, which is where to start. `mdadm` now ships in the guest, and a
  two-disk RAID1 mounts through the engine with a copy reading back
  byte-identical. What is left is the app side.
- [ ] **Re-decide ZFS.** `trim-image.py` drops `zfs` and `zfs-libs`, and the
  kernel modules are now dropped as well, so neither the weight nor the
  capability ships. The re-decision has a licence dimension as well as a size
  one: ZFS is CDDL, the long-running incompatibility with a GPL-2 kernel, and
  this app is GPL-3-or-later distributing that guest. Decide it on purpose and
  write the reason down, whichever way it goes.
- [ ] Go through the rest the same way: F2FS, squashfs (`squashfs-tools` is
  also dropped), UDF, and the FreeBSD image the engine can boot for UFS. For
  each: does the guest kernel have the driver, does the guest have the tools,
  does the app offer it, does `DiskWatcher` claim the type. Those four should
  agree.

## Re-test every format we claim, read and write

The formats were added at different times and tested to different depths. XFS
sat in the advertised list for months with a stub standing in for a fixture and
nothing had ever opened one.

- [x] **The image formats are swept.** `format-write-sweep.sh` puts the corpus
  through every format the app says it can write: qcow2, VDI, VHD fixed and
  dynamic, sparse VMDK. 5 of 5, 2024 identical, 0 differing, 0 missing. Before
  this the write paths had only their unit tests against `qemu-img`.
- [x] **The vectors run against NTFS as well as XFS.** Eleven of eleven on an
  NTFS image, including the fsync-across-a-kill case XFS fails: 8 of 8 fsynced
  files present, 0 wrong, 0 lost. An image is a regular file, so this says
  nothing about a physical drive.
- [ ] **ext4 loses fsynced content across a killed machine, and NTFS does not.**
  Measured on images, with the flush patch in, so the device branch never runs
  and cannot be the cause: NTFS 8 of 8 present and 0 wrong; ext4 8 of 8 present
  and **8 wrong**, with 30 of 30 in-flight files back at full length and none
  complete; XFS 32768 bytes of holes at offset 0.

  Ruled out already: the guest mounts ext4 `rw,relatime`, which is
  `data=ordered` with barriers on, and `/sys/block/vda/queue/write_cache` reads
  `write back`, so the guest believes there is a cache and does issue flushes.
  Same virtio path and same host flush as NTFS, which keeps its content.

  The next cheap test is `data=journal` on ext4. If that passes, the cause is
  ordered mode and the question becomes what full data journalling costs a copy.

- [ ] Still wanted: `integrity-vectors.sh` against btrfs, and
  `xattr-forks.sh` against each filesystem rather than only NTFS, results
  written into `make-format-volumes.sh` beside the ones already there.
- [ ] **Build ntfsck into the guest and gate the ntfs3 probe on it.** The probe
  in `MountScript.ntfs3Probe` asks whether ntfs3 will mount read-only, which is
  a proxy for "is this volume sound". It costs nothing on the corpus as it
  stands, and the next volume it is wrong about will be wrong silently. ntfsck
  from ntfsprogs-plus checks structure instead of inferring it from a driver's
  consent. GPL-2, aggregates in the guest; Alpine does not package it, so it
  means building from source.
- [ ] Look upstream before hand-rolling. `ntfsprogs-plus` provides `ntfsck`,
  which repairs structural damage our ladder can only refuse. The engine's own
  test suite (`tests/*.bats`) covers cases we re-derived by hand.
- [ ] **Prove a saved passphrase survives every format on real media.** The
  identity a saved passphrase is filed under now comes from the volume's own
  header rather than from the partition table, and `volumeIdentity` covers all
  nine formats on headers built for the test. What is not covered is the same
  question asked of real drives: save a passphrase, replug the drive somewhere
  else so it comes back as a different diskNsM, and open it without being asked
  again. Each of BitLocker on MBR and on GPT, BitLocker To Go, LUKS on a whole
  disk and in a partition, LUKS holding ext4, btrfs, XFS and an LVM group, and a
  container file of each image format. If a passphrase was saved it is saved.
