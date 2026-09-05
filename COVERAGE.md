# Coverage: what Lukotta opens, what it does not, and how to close every gap

The plan for the v2 line, and the reason this branch exists. v1 stays on the
formats it already opens; the work below is what v2 adds. Every route here was
read out of this repository on 2026-09-04 — the guest's own `modules.builtin`,
upstream anylinuxfs's source, SPECS.md and TODO.md — rather than recalled, and
each claim says which.

The question this answers: **what could this app open that it does not open
today, and what is the actual route to shipping each one** — technically and
legally. Not a list of reasons something is hard.

## How to read it

Every gap below is one row in a table and one section of prose. The row says
what it is and whether the route is open; the prose says how to walk it. A gap
with no route is stated as such and the reason is a mechanism, not a shrug.

Three positions a new component can occupy, and the legal question is different
in each:

1. **Linked into the app** — Swift, in-process. GPL-3.0-or-later governs.
2. **Aggregated in the guest** — a file in the Alpine image inside the bundle,
   run as a separate program in a virtual machine. Mere aggregation.
3. **A separate process on the Mac** — spawned, talks over a pipe or a socket.

Most of what follows belongs in position 2, which is the loosest of the three,
and that is the single most important fact about this app's ability to grow.

## The baseline: what is claimed today

Read from SPECS.md §1 on 2026-09-04.

### Filesystems

| Filesystem | Today | Where |
| --- | --- | --- |
| NTFS | read-write | guest, `ntfs3` then `ntfs-3g` |
| ext2, ext3, ext4 | read-write | guest, in-kernel |
| btrfs | read-write | guest, in-kernel |
| XFS | read-write | guest, in-kernel |
| exFAT, FAT | read-write | handed to macOS |
| APFS, HFS+ | read-write | handed to macOS; guest has no driver |

The guest is an Alpine image of 66 packages carrying `ntfs-3g`, `btrfs-progs`,
`e2fsprogs`, `cryptsetup` and `lvm2`. A filesystem outside that list cannot be
mounted.

### Encryption

| Scheme | Today |
| --- | --- |
| BitLocker | opened, `cryptsetup bitlkOpen` |
| LUKS1, LUKS2 | opened, `cryptsetup open` |
| FileVault 2 | not opened; macOS does it |
| VeraCrypt, TrueCrypt | not opened; `tcrypt` is present in cryptsetup and not reachable |
| Encryption applied by an image format | not opened |

### Volume managers

LVM volume groups are discovered and opened, including inside an encrypted
container. Linux software RAID is recognised by the engine — and, per SPECS.md
§8, is claimed by the app without being openable, which is a gap that already
has a user consequence.

### Disk images

| Format | Read | Write |
| --- | --- | --- |
| Raw (`.img`, `.dmg`, unrecognised) | yes | yes |
| qcow2 | yes | yes |
| VMDK flat | yes | yes |
| VMDK sparse | yes | yes |
| VMDK stream-optimized | yes | no |
| VDI dynamic and fixed | yes | yes |
| VHD fixed and dynamic | yes | yes |
| VHDX | yes | no |
| VMDK snapshot chains, VHD differencing, VHDX with a parent | no | — |
| VHDX with a non-empty log | no | — |
| Sparse bundles, encrypted DMG | no | — |

The VMDK, VDI, VHD and VHDX drivers were written in this project for imago.

---

## What the app declares unsupported today, and what each would actually take

Read from SPECS.md §5 on 2026-09-04. This is the list the owner asked about
directly — "lets support everything we claim not to support this far". Several
of these are far closer than the prose suggests, because the capability is
already inside the guest and only the app side is missing.

### VeraCrypt and TrueCrypt — the component is already shipped

SPECS.md §5 states it plainly: cryptsetup carries its own `tcrypt`
implementation and **it is in the guest already**. No new dependency, no new
licence. The only obstacle recorded is that the engine decides what to unlock
from what `blkid` reports, and a TrueCrypt header is indistinguishable from
random data by design, so nothing reports it. SPECS.md concludes that opening
one "requires the person to state that a device holds a TrueCrypt volume".

**That conclusion is the one thing here worth overturning, and the guiding star
overturns it.** Asking a person to declare a container's type is exactly the
choice this project refuses to hand back. The volume is unidentifiable *by
design*, which means the app already knows the only two states it can be in:
either something identified it, or nothing did. Where nothing did and the person
is being asked for a passphrase anyway, `tcrypt` is simply another rung on the
ladder the app already walks — attempted with the passphrase in hand, costing
one failed unlock attempt when the guess is wrong, and no click and no question
when it is right.

Route: add a `tcrypt` rung below the existing ones, reached only when no
signature was found; carry the hidden-volume and system-encryption variants as
further attempts on the same passphrase. Cost is unlock latency on
unidentifiable devices, which today produce a refusal instead. No new licence,
no new package, no new screen.

### FileVault 2 — blocked on a filesystem driver, not on the unlock

cryptsetup's `fvault2` handler exists and, per SPECS.md, "leads nowhere without
a filesystem driver behind it", the guest having neither HFS+ nor APFS. Two
routes, and they are genuinely different:

1. **Put a driver in the guest** — HFS+ has an in-kernel Linux driver; APFS has
   `apfs-fuse` and the `linux-apfs-rw` out-of-tree module. Licences and maturity
   are covered in the research sections below.
2. **Unlock in the guest, hand the device back to macOS.** The app already has a
   route for handing volumes to macOS (SPECS.md §4, how exFAT and FAT are
   served). A FileVault volume unlocked by `fvault2` exposes a plain HFS+/APFS
   device, and macOS has the best driver for both in existence. This is the
   route the guiding star prefers: it reuses a path that exists, needs no new
   driver, and gives the person Apple's own filesystem implementation.

The case for doing it at all is volumes macOS refuses — a disk from a Mac that
will not boot, an old CoreStorage volume, a drive whose recovery is exactly what
this app is for.

### Encrypted DMG and sparse bundles

Declared unsupported because macOS opens both natively and integrates them with
Keychain and Finder. That reasoning holds while the file is healthy. It stops
holding for a damaged one, a sparsebundle with missing bands, or a Time Machine
bundle macOS will not attach — which is precisely the recovery case. Route and
components in the image-formats research below.

### Stream-optimized VMDK inside an OVA — an archive, not a format gap

SPECS.md is explicit: the format itself is read; an OVA is a tar carrying a
descriptor and one of these images, and "Lukotta does not extract archives".
This is the cheapest win in the whole document. The app can read the tar,
find the descriptor, and open the `.vmdk` inside it — no new driver, no new
licence, no guest change. Under the guiding star, telling somebody to extract
the file themselves is the failure; the app should just open what it was given.

### Writing to a VHDX, and a VHDX with a non-empty log

Both stem from one missing piece: the log. SPECS.md sets out the requirement
precisely — every change to the allocation table or metadata is written into the
log first, and a writer must stamp a new identifier into one of the two headers,
each carrying a sequence number and a CRC-32C. A writer that skips the log
leaves damage that cannot be detected afterwards, so the log is a precondition
for writing at all.

For the dirty-log case SPECS.md has already identified the route and the real
obstacle: `readv_special()` lets a driver serve bytes itself, so a log can be
replayed **into memory** without writing to the file — and the obstacle is not
the code, it is verification. "A genuinely dirty image is difficult to obtain,
and an image written by the same author as the reader tests only that they agree
with each other."

That is a fixture problem, and fixture problems have routes: produce dirty
images with Hyper-V itself or with a third-party writer, so the reader and the
writer are not the same author. Where a Windows host is unavailable, the same
independence is obtained from any implementation not derived from ours.

### qemu in the guest — the largest single lever, already scoped

SPECS.md §5 records that borrowing QEMU's block layer was measured, and exactly
why each route stalled:

- `CONFIG_BLK_DEV_NBD` is not set in the kernel libkrunfw builds and is not
  available as a module, so `qemu-nbd` has nothing to attach to. Turning it on
  means building and shipping a kernel of our own.
- `CONFIG_FUSE_FS=y` and `CONFIG_BLK_DEV_LOOP=y`, so a FUSE export could be
  attached with `losetup`. Alpine packages `qemu-storage-daemon` inside its
  `qemu-img` subpackage but builds it **without `fuse3`**, so the export type is
  absent. Using it means building QEMU's tools for aarch64-musl with fuse3 and
  shipping them in the guest.

Both are recorded as open. The second one is the lever: QEMU's block layer has
written every one of these formats for years, and the blocker is a build flag in
somebody else's package, not a design problem. Building `qemu-storage-daemon`
with fuse3 for aarch64-musl — the same kind of work `build-ntfsck.sh` already
does for the NTFS checker, in a container, shipping one binary into the guest —
converts a long tail of image formats from "a driver we would have to write"
into "a format qemu already handles". QEMU is GPL-2.0-only, which aggregates in
the guest and must not be linked into the app; running it as a separate program
in the virtual machine is exactly the position that makes that fine.

The counterweight, stated honestly: it exposes the image file to the guest,
which never sees it today, and that is a real change to the trust boundary
worth designing deliberately rather than sliding into.

### A symbolic link whose target is not plain ASCII

Not a gap to close — a decided trade recorded in SPECS.md and in AGENTS.md. The
`nfc` mount option is what makes names written on a Linux volume come back the
way they were typed, and the same option refuses a symlink whose target holds
both a separator and a non-ASCII character. Names are what every volume is full
of; this shape of link is rare. The decision stands, and the end-to-end run
asserts both halves so a change underneath is noticed.

---

## 1. Filesystems not covered at all

The single most useful fact in this section was read from the shipped guest
itself, not assumed: `vendor/engine/alpine/rootfs.tar.gz` carries **no loadable
kernel modules at all** — `lib/modules/6.12.62/` holds only the `modules.builtin`
metadata files. Every driver the guest has is compiled into the libkrunfw
6.12.62 kernel, and `modules.builtin` lists exactly which. (Upstream anylinuxfs
downloads a separate `modules.squashfs` at init for the rest — see §2 — and
none of it survives into what Lukotta vendors.)

Built into the guest kernel today, per `modules.builtin`: **ext4, btrfs, XFS,
ntfs3, FAT/vfat, exFAT, F2FS, EROFS, squashfs, bcachefs, FUSE (+virtiofs),
overlayfs, cifs (SMB client), ksmbd, NFS client and server**, plus loop,
dm-crypt, md raid0/1/10/456 and the LVM device-mapper targets.

**Not** in that kernel: iso9660, UDF, HFS, HFS+, APFS, NILFS2, JFS, ReiserFS,
minix, cramfs, UFS, OCFS2, GFS2, befs, affs, ZFS. Anything on that list needs
one of three routes: a FUSE userspace driver dropped into the guest (FUSE is
built in, so this is pure aggregation, the `build-ntfsck.sh` pattern), a
libkrunfw kernel built here with the option turned on (SPECS.md §5 already
names this lever for NBD; the kernel is GPL-2 and its binary is already
redistributed, so a rebuilt one changes nothing legally — it costs the build
and the corresponding-source publication), or handing the volume to macOS.

A second cross-cutting fact: `DiskWatcher.ourContent`
(sources/LukottaCore/DiskWatcher.swift) claims partitions by **type GUID**, and
every Linux filesystem shares one GUID, `0FC63DAF-8483-4772-8E79-3D69D8477DE4`.
So a partition holding F2FS, EROFS, bcachefs or NILFS2 is **already claimed
today** — macOS is already told not to offer to initialise it — while the
first-sector probe (sources/LukottaCore/BootSector.swift) recognises only
luks/ext/btrfs/xfs and answers `.unknown` for the rest. That is the RAID
defect's shape repeated: claimed, then not opened. Every Tier-A filesystem
below closes one instance of it.

### What trim-image.py deliberately drops, and why

Read from `scripts/trim-image.py` and upstream's
`init-rootfs/default-alpine-packages.txt` (in
`vendor/.cache/source/anylinuxfs-0.19.0/`). Upstream installs `bash, blkid,
btrfs-progs, cryptsetup, lsblk, lvm2, mdadm, mount, nfs-utils, ntfs-3g,
ntfs-3g-progs, squashfs-tools, zfs`. Lukotta's trim keeps only the dependency
closure of the ROOTS list — cryptsetup, ntfs-3g(+progs), lvm2, mdadm,
e2fsprogs, btrfs-progs, xfsprogs, nfs-utils, rpcbind, mount/blkid/lsblk and the
base system — so **`squashfs-tools` and the `zfs` userspace are dropped**, and
`zfs.ko`/`spl.ko` are removed by path because no package owns them (they are
baked into the base image's module tree; the script's own comment records that
dropping the packages alone shipped the modules anyway, contradicting
THIRD_PARTY_NOTICES.md). The stated reasons, in the script and in
vendor-engine.sh: dead weight, download size, and "every GPL package shipped is
a package whose source must be published alongside the release" — the trim
shrinks the compliance surface together with the archive. Adding a filesystem
therefore always touches the same four files: `trim-image.py` ROOTS, the
`anylinuxfs apk add` step vendor-engine.sh documents, `THIRD_PARTY_NOTICES.md`
(regenerated by `scripts/generate-notices.sh`), and `vendor/guest-sbom.json`
(written by the repack).

### Tier A — the kernel driver already ships; only tools and app wiring are missing

| Filesystem | Kernel | Tools to add | Licence | Realistic mode |
| --- | --- | --- | --- | --- |
| F2FS | built in | `f2fs-tools` (Alpine packages it) | GPL-2.0 | read-write |
| EROFS | built in | `erofs-utils` (Alpine packages it) | GPL-2.0-or-later (parts dual Apache-2.0) | read-only — EROFS is a read-only filesystem by design |
| squashfs | built in | `squashfs-tools` (Alpine packages it; upstream's image carried it before the trim) | GPL-2.0 | read-only by design |
| bcachefs | built in | `bcachefs-tools` (in Alpine's repositories) | GPL-2.0 | read-write, with the caveat that the filesystem itself is young and was in upstream turmoil through 2024–25; offer it, mark it, test it |
| exFAT | built in | `exfatprogs` | GPL-2.0 | deliberately handed to macOS (SPECS.md §4) — the guest driver matters only for the repair case in §4 below |

Route, identical for all four Linux ones: add the magic to
`BootSector.swift` and a case to `VolumeFormat` (whose
`filesystemName(fromDriver:)` already maps `"f2fs"`, so the naming half exists),
let the existing Linux mount ladder in `MountScript.swift` carry it — the
engine mounts by what `blkid` reports, and the kernel driver answers — add the
tools package for repair, and add corpus coverage in
`make-format-volumes.sh`/`copy-torture.sh`. `DiskWatcher` needs no change: the
GUID is already claimed. F2FS is the highest-value one (every Android phone,
many SBCs, Steam Deck SD cards); squashfs and EROFS open every Linux live-USB
and Android system image (see §5). Cost per filesystem: days, no new licence
class, a few hundred KB of guest.

### Tier B — no kernel driver; FUSE in the guest, a rebuilt kernel, or macOS

| Filesystem | Best route | Component, licence | Mode |
| --- | --- | --- | --- |
| HFS+ | hand to macOS (healthy); guest for recovery: rebuild kernel with `CONFIG_HFSPLUS_FS` (driver is in 6.12), plus `hfsprogs` (fsck_hfs port) built from source — Alpine does not package it | kernel driver GPL-2; hfsprogs is **APSL-2.0** — FSF-approved free, GPL-incompatible, fine as a separate program aggregated in the guest, never linkable into anything GPL | Linux HFS+ write support is old and journalling-unaware: read-only in practice, or read-write only on unjournalled volumes |
| HFS (classic) | same kernel rebuild, `CONFIG_HFS_FS` | GPL-2 | read-only realistically; floppy-era archives |
| APFS | hand to macOS (healthy — SPECS.md already routes it there); for the FileVault-2/recovery case the file's earlier section names: `apfs-fuse` in the guest (FUSE is built in) or the `linux-apfs-rw` out-of-tree module against a rebuilt kernel | apfs-fuse GPL-2.0-or-later, github.com/sgan81/apfs-fuse; linux-apfs-rw GPL-2.0-only, github.com/linux-apfs/linux-apfs-rw | read-only (apfs-fuse is read-only; linux-apfs-rw's write support is labelled experimental by its own authors — do not ship it writable) |
| UDF | see §5 — as an optical *image*, macOS attaches it natively; a UDF *hard drive partition* needs `CONFIG_UDF_FS` in a rebuilt kernel plus `udftools` (GPL-2, in Alpine) | GPL-2 | read-write is real for UDF 2.01 rev on block devices |
| NILFS2 | rebuilt kernel + `nilfs-utils` | GPL-2 (tools), LGPL-2.1 (lib) | read-write; niche but its continuous snapshots are a genuine recovery feature |
| JFS | rebuilt kernel + `jfsutils` (check aports; else the build-ntfsck.sh pattern) | GPL-2+ | read-write; moribund upstream, old NAS boxes are the audience |
| ReiserFS | 6.12 still contains the driver (removed from mainline in 6.13, so a future kernel bump closes this door); rebuilt kernel + `reiserfsprogs` | GPL-2 | read-only recommended; the audience is people with 2005-era disks |
| minix, cramfs | rebuilt kernel; util-linux fsck.minix | GPL-2 | trivially small; read-only; near-zero audience — do them only because the kernel rebuild makes them a config line each |
| UFS/FFS | the Linux UFS driver is read-only and poor. The real route is the one upstream anylinuxfs already built: a **FreeBSD guest** (`etc/anylinuxfs.toml` defines `freebsd-15.0/15.1` images with FreeBSD kernels), whose UFS support is native and read-write | FreeBSD kernel: BSD-2-Clause | read-write via FreeBSD guest; read-only via Linux |
| OCFS2, GFS2 | rebuilt kernel (+ ocfs2-tools GPL-2); both mount single-node with `local` heartbeat | GPL-2 | read-write; vanishingly rare outside clusters — lowest priority |
| befs, affs | rebuilt kernel | GPL-2 | read-only; archaeology |

The kernel rebuild is one piece of work that unlocks eight rows of this table
at a config line each, and SPECS.md §5 already wants it for NBD. It is the
second-largest lever in this document after qemu-storage-daemon.

### Tier C — no open route exists

| Case | State | Nearest thing that works |
| --- | --- | --- |
| ReFS | No published specification, no production open-source implementation, actively changed by Microsoft. One sentence: there is no route. | Paragon sells a proprietary Linux ReFS driver; a proprietary-with-redistribution component could in principle be aggregated in the guest (see §6), at a price and quality nobody outside an NDA can audit. Otherwise: tell the person to copy the data off under Windows. |
| NTFS EFS-encrypted files | The stack already ships the answer in embryo: `ntfsdecrypt` is part of ntfs-3g-progs (already in the guest) and decrypts EFS files given the user's exported key (PFX). No route without the key — that is the cryptography working. | Detect the EFS reparse/attribute, say "these files are EFS-encrypted; export the key from Windows (cipher /x) and Lukotta can decrypt them", wire ntfsdecrypt. |
| NTFS compressed files | Not actually a gap: ntfs3 and ntfs-3g both read LZNT1-compressed files today, and ntfs-3g writes them. **WOF/CompactOS "system compression"** is the real gap — files compacted by Windows 10+ read as zero bytes through plain ntfs-3g. `ntfs-3g-system-compression` (Eric Biggers' plugin, GPL) reads them; build it into the guest beside ntfs-3g. | Ship the plugin; read-only for WOF files, which is what Windows itself does outside the WOF driver. |
| Windows Server deduplicated volumes | Chunk-store format is reverse-engineered only in forensic research; no open mounter. No route worth building. | Detect the dedup reparse points and say so, rather than serving files that read as empty. |

---

## 2. ZFS and its licence, in depth

### What the incompatibility actually is

ZFS is under the CDDL-1.0, a file-level copyleft Sun wrote in 2005 —
deliberately or not, its terms (notably choice-of-licence and patent clauses)
cannot be satisfied simultaneously with the GPL's "no further restrictions" for
one combined work. The Linux kernel is GPL-2.0-only. Nobody disputes that the
two licences are incompatible *for a single derivative work*; the entire fight
is over whether kernel + zfs.ko **is** one work.

The positions, each with its primary source:

- **Software Freedom Conservancy** (Kuhn/Sandler, 2016-02-25): distributing a
  built zfs.ko together with Linux is a GPL violation; a kernel module is
  derivative of the kernel. They asked Oracle to relicense.
  https://sfconservancy.org/blog/2016/feb/25/zfs-and-linux/
- **FSF** (2016-04-11 statement, and RMS's analysis): supports the
  Conservancy's reading; CDDL and GPL cannot be combined in one program.
  https://www.fsf.org/licensing/zfs-and-linux and
  https://sfconservancy.org/blog/2016/apr/11/fsf-zfs/
- **Canonical** (Kirkland, 2016): zfs.ko is a self-contained module, derivative
  of OpenSolaris/OpenZFS, not of Linux; shipping it complies with both
  licences. Ubuntu has shipped zfs.ko in every release since 16.04 — ten years
  now — and no copyright holder has sued.
  https://ubuntu.com/blog/zfs-licensing-and-linux
- **SFLC** (Moglen/Choudhary, 2016): the middle reading — literal GPL text is
  against it, but distribution of the module built as a separate object, where
  the combination conveys no licence statement about the kernel, sits in a
  tolerated equilibrium. https://softwarefreedom.org/resources/2016/linux-kernel-cddl.html
- **Oracle**: has said nothing, relicensed nothing, and sued nobody over it in
  twenty years. Oracle's silence is the load-bearing wall of the entire
  ecosystem, and it is a wall someone else owns.

None of this is settled law. No court has ruled on kernel-module
derivativeness. It is industry practice (Ubuntu, Proxmox, TrueNAS SCALE all
ship it) standing against the two most credible enforcement bodies' stated
reading. That asymmetry — who would sue is exactly who has said it is a
violation — is the risk, and it attaches to *distributing the combination*,
nothing else.

### Whether it bites HERE

The GPL-3 macOS app is a red herring, and the file's own three-position
framework disposes of it: the app never links ZFS, never contains ZFS, and a
guest image in the bundle is mere aggregation (GPLv3 §5, and
THIRD_PARTY_NOTICES.md already states the separate-programs analysis for the
GPL-2 kernel itself). The only live question is the one inside the guest image:
**kernel + zfs.ko in one distributed artifact** is precisely the
Conservancy/Canonical fight. CDDL *userspace* (`zpool`, `zfs`, libzfs) beside a
GPL-2 kernel is uncontroversial aggregation — the incompatibility argument is
about the kernel module alone.

### What upstream anylinuxfs actually does — read from its source, not assumed

From `vendor/.cache/source/anylinuxfs-0.19.0/`:

- `init-rootfs/default-alpine-packages.txt` installs the `zfs` userspace
  package from Alpine into the guest at **init time on the user's machine**.
- `etc/anylinuxfs.toml` points `kernel.modules_url` at
  `https://github.com/nohajc/libkrunfw/releases/download/v6.12.62-rev1/modules.squashfs`,
  and `init-rootfs/main.go` (line ~345) unsquashes it into the module tree —
  so **zfs.ko/spl.ko are downloaded separately at init and combined on the
  user's machine**; the anylinuxfs release artifact itself never contains
  kernel and module together.
- `vmproxy/src/zfs.rs` implements `zpool import` discovery and `zfs list -j`
  parsing; `tests/06-zfs.bats` mounts unencrypted and natively-encrypted pools
  (via `ALFS_PASSPHRASE`) with `modprobe zfs`; a `--zfs-os linux|freebsd`
  option chooses the implementation.
- `etc/anylinuxfs.toml` also defines **FreeBSD 15.0/15.1 guest images** with
  FreeBSD kernels (`os_type = "FreeBSD"`), and `tests/16-freebsd-zfs-multi.bats`
  exercises ZFS through them. In FreeBSD the CDDL filesystem sits in a
  BSD-licensed kernel: no copyleft conflict exists at all.
- There is even a `custom_actions.ubuntu_zfs_unlock` for Ubuntu's
  LUKS-keystore-inside-zvol layout.

So upstream's answer is: userspace from Alpine, module by separate download
combined client-side, FreeBSD guest as an alternative — and Lukotta's trim
removes all of it because Lukotta *ships* the guest instead of downloading it,
which is exactly the step that converts upstream's safe posture into the
contested one.

### The routes, ranked

1. **FreeBSD guest for ZFS volumes** — the clean kill. CDDL module in a
   BSD-2-Clause kernel: no GPL anywhere in the combination, nothing contested,
   full native read-write ZFS including native encryption, and the engine
   Lukotta already vendors has the machinery (`--zfs-os freebsd`, the freebsd
   feature flag in `anylinuxfs/src/cli.rs`, the image definitions, passing
   tests). Cost: vendoring and trimming a second guest OS (~a FreeBSD base
   image + custom kernel bundle from nohajc/freebsd releases), a second
   test matrix, tens of MB in the bundle, and the app growing a "which guest"
   axis. Entirely engineering, zero legal novelty.
2. **Do what upstream does: download-and-combine at init, opt-in.** Ship no
   ZFS byte; on first encounter with a zpool, offer to fetch `modules.squashfs`
   and `zfs` userspace, combined on the user's machine like Ubuntu's DKMS-era
   posture, which even the Conservancy treats differently from distribution.
   Cost: it breaks vendor-engine.sh's stated rule that "the app must not
   download anything on first run" — but as an explicit, once, user-consented
   action for an optional capability, that rule can keep its spirit; plus
   pinning/checksumming the download, and the UX of a fetch step.
3. **Ship kernel + zfs.ko in the guest image** — the Ubuntu posture. A decade
   of precedent, no suit ever, and large companies with counsel do it. But
   Lukotta would be adopting the position the two likeliest enforcers call a
   violation, in a product whose whole legal story is currently spotless and
   self-documented. Take this route only after real legal advice, and record
   the reasoning in THIRD_PARTY_NOTICES.md as deliberately as the current
   removal is recorded.
4. **Userspace/FUSE ZFS** — no. zfs-fuse is dead (last real release ~2011,
   ancient pool versions only), OpenZFS has no maintained FUSE port. The
   nearest living thing is route 1.
5. **Linking anything ZFS into the app** — never; CDDL is incompatible with
   GPL-3 in both directions.

The build order at the end of this file places route 1 accordingly. Note also
`SPECS.md §8` and `TODO.md` both demand this decision be *written down*
whichever way it goes — this section is the input to that decision, not the
decision.

---

## 3. Physical devices not covered

The app's device model today is "a block device macOS attaches, read raw by
the privileged helper, served to the guest" plus "an image file". Everything
below is sorted by how far it sits from that model.

### Already inside the model, no work needed beyond §1

SD and camera cards, CompactFlash in a reader, eMMC/UFS behind a USB reader,
and hardware-RAID enclosures all present as ordinary USB mass-storage block
devices. They are covered exactly as far as their *filesystem* is: FAT/exFAT
cards go to macOS today, ext4 cards open today, F2FS cards (Steam Deck,
Android) open the day §1 Tier A lands. Nothing device-specific to build.

### Linux software RAID — the live defect, and its fix

SPECS.md §8 and TODO.md agree on the facts: `DiskWatcher.ourContent` claims the
Linux RAID GUID `A19D880F-05FC-4D3B-A006-743F0F84911E`, so a member disk is
protected from Disk Utility's initialise offer — and then nothing in the app
can open it, because `assemble_raid` is set only on the `raid:` and `lvm:`
branches of the engine's `cmd_mount.rs`, and the app never constructs a
`raid:<devA>[:<devB>...]` identifier. The layer below is proven: mdadm ships in
the guest (trim-image.py keeps it, with a comment saying exactly why), and a
two-disk RAID1 mounts through `raid:a.img:b.img` with byte-identical copies.

The fix, concretely: in the drive survey, group partitions whose `blkid` type
is `linux_raid_member` by their array UUID (`mdadm --examine` or blkid's
`MD_UUID`), present the *array* as one row instead of N unreadable disks,
and hand the engine `raid:` plus the member device list.
`VolumeGroupParser`/`LogicalVolume` (sources/LukottaCore/VolumeGroups.swift)
already carry a `scheme` field whose values are `lvm` and `raid` and already
skip `linux_raid_member` as a non-mountable container, so the identifier
plumbing exists; what is missing is the grouping step in
DriveSurvey/Drives/AppModel and the degraded-array story (a mirror with one
member present should open read-only with a warning, not sit unopenable — that
is the same claimed-then-refused trap one disk smaller). Files:
`sources/LukottaCore/DriveSurvey.swift`, `Drives.swift`,
`sources/Lukotta/AppModel.swift`; the engine needs nothing.

### Optical drives — CD, DVD, Blu-ray

A USB optical drive attaches as a device and macOS mounts ISO 9660, Joliet,
HFS-hybrid and UDF natively, multisession included. The guest kernel has
neither iso9660 nor UDF (§1), so the right route is the one SPECS.md §4
already walks for exFAT: recognise it, hand it to macOS, say so. Work: a
verdict row, not a driver. Where Lukotta genuinely adds value:

- **Damaged discs.** macOS gives up early on scratched media. GNU ddrescue
  (GPL-3, spawned as a separate process — same licence family as the app)
  imaging `/dev/rdisk` to a file, then opening the image, is a real recovery
  feature no Mac tool ships.
- **Blu-ray data discs** are UDF 2.5/2.6: macOS mounts them. **AACS-encrypted
  video discs are a legal question, not a technical one** — see §6; the
  technique exists (libaacs) and shipping it is DMCA §1201 exposure. One
  sentence: no route Lukotta should ship; the nearest thing that works is
  MakeMKV, which the person installs themselves.
- Audio CDs are not a filesystem; out of scope.

### iSCSI and NBD — network block devices

macOS has **no iSCSI initiator at all**, so this is a genuine gap Lukotta could
own. The guest kernel has neither `iscsi_tcp` nor `nbd` (verified in
modules.builtin; SPECS.md §5 records the NBD half), but both fall to the
**qemu-storage-daemon lever the file already scopes**: qemu's block layer is a
userspace iSCSI client (via libiscsi, LGPL-2.1) and a userspace NBD client, and
its FUSE export plus the built-in loop driver turns either into a block device
inside the guest with no kernel change. One build (qemu tools for aarch64-musl
with fuse3 and libiscsi, GPL-2 aggregated in the guest) buys iSCSI, NBD, and
the §5 image formats at once. The guest reaches the LAN through vmnet
(patches/anylinuxfs-vmnet-reachable.patch exists precisely to make the guest
addressable), so the network path is plumbed; what needs design is the UI for
a target/portal and credentials. Cost: the qemu build, plus CHAP handling.

### NAS shares — SMB, NFS, AFP

macOS mounts SMB and NFS natively and still carries an AFP client; Finder does
this well, and re-serving a share over another share adds a layer for nothing.
Not Lukotta's job, with one honest exception: ancient dialects. The guest
kernel's cifs client can speak SMB1 to a 2005 NAS that modern macOS refuses
politely or mounts unreliably. That is a corner: possible through the same
"mount in guest, re-export" machinery with a URL instead of a device, cheap
once iSCSI's target-entry UI exists, and worth doing only if users actually
surface with such boxes.

### iOS devices

Without a jailbreak, the reachable surface — through usbmuxd and
libimobiledevice (libraries LGPL-2.1, tools GPL-2) — is: the media folder
(DCIM, photos, videos) over AFC; the Documents sandbox of each app that opts
into file sharing, over house_arrest; and full device backups over
mobilebackup2 (readable only with the backup password if one is set). The
filesystem itself is not reachable, and saying otherwise would be false
advertising. macOS already surfaces photos and per-app documents in Finder, so
the value added is thin: browsing an *existing backup* as a filesystem is the
one real feature (the backup is a hashed file store; presenting it as its
logical tree is genuine added value for recovery). Route: host-side, position
3 — the USB device cannot reach the guest, libkrun having no USB passthrough
(my reading of the stack; verify before relying on it) — with LGPL-2.1
libraries that could even be linked. Cost: a full subsystem with its own UI;
low coverage-per-work, ranked accordingly.

### Android devices

Modern Android exposes MTP/PTP, not mass storage; the eMMC-as-mass-storage era
ended around Android 6. MTP (libmtp, LGPL-2.1) has no random access, no
partial reads, no rename-into-place — it maps so badly onto a filesystem that
presenting it through NFS would produce Finder timeouts by design. The honest
routes: a transfer window in the app (host-side, LGPL), or adb (Apache-2.0)
for developer-enabled devices, or nothing, with Google's own Android File
Transfer as the nearest existing thing. fastboot matters only as a source of
partition *images*, which then hit §5's Android formats. A dead phone's eMMC
in a USB reader is just a block device: ext4/F2FS/EROFS coverage handles it,
minus file-based encryption, which is unopenable without the device's keys —
one sentence: no route, by design of FBE.

### Tape and LTFS

LTFS makes a tape look like a filesystem; the reference implementation
(LinearTapeFileSystem/ltfs, LGPL-2.1) is FUSE-based and has a macOS port used
by vendors. It needs a SAS/Thunderbolt HBA whose driver exposes SCSI
pass-through on macOS, and macFUSE or an FSKit shim on the host — the guest
cannot see the drive (no USB/SCSI passthrough into libkrun). Possible
host-side with entirely compatible licences; enormous per-user cost for a tiny
audience; do it never, or as a paid-consulting fork.

### Enterprise oddities

- **520/528-byte-sector drives**: USB bridges refuse them and macOS has no SAS
  HBA story to speak of. One sentence: no realistic route on a Mac. Nearest
  thing: `sg_format` on a Linux box to reformat to 512 (destroys data), then
  read here.
- **OPAL / eDrive hardware encryption**: unlocking needs TCG commands
  (TRUSTED SEND/RECEIVE) through the host controller; sedutil (GPL-2) does not
  support macOS and macOS does not expose the passthrough. One sentence: no
  route on macOS today. Nearest: unlock on a Linux machine or via the drive's
  PBA, then plug in here — an unlocked OPAL drive reads as a normal disk and
  everything else in this document applies to it.

---

## 4. Doing better what macOS already does

macOS mounts FAT, exFAT, HFS+ and APFS read-write and NTFS read-only. The
app's existing posture (SPECS.md §4) is to stand aside where macOS is the
better tool — correctly. "Better" therefore means one of four things: repair
macOS cannot do, mounting what macOS refuses, recovering what macOS has given
up on, or writing where macOS will not. Ranked by how real the win is:

### NTFS read-write and dirty repair — the product, already ahead

Shipped and measured: read-write against macOS's read-only, the
ntfs3→ntfs-3g ladder that mounts volumes Windows left dirty, and repair that
Apple has no equivalent of at all — `ntfsck` built from ntfsprogs-plus by
`scripts/build-ntfsck.sh`, the 83-image corrupt-corpus run, and the real
$MFTMirr repair on hardware (SPECS.md §7). This section's remaining NTFS items
are in §1 Tier C (WOF compression plugin, EFS with the user's key).

### Repair with fsck variants Apple does not ship — cheap, real

Apple's `fsck_msdos` and `fsck_exfat` are minimal. The upstream tools are not:
`fsck.fat` from dosfstools (GPL-3) and especially `fsck.exfat` from exfatprogs
(GPL-2, Samsung, actively developed alongside the exfat kernel driver) repair
classes of damage Apple's tools only report. The guest kernel already has
vfat and exfat built in (§1), so the route is: when macOS *fails* to mount a
card — and only then, the §4 stand-aside holds for healthy media — offer the
guest ladder: mount attempt, fsck, remount, exactly the shape
`MountScript.swift` already implements for NTFS. Camera cards are the single
most common broken-volume case the public has. Cost: two packages, one ladder
extension, corpus fixtures of deliberately-corrupted FAT/exFAT.

### Bad-sector tolerance — the biggest missing recovery feature

Every mount path in the app assumes the device answers reads. A failing drive
does not, and both macOS and the guest kernel respond with long timeouts and
eventual eject. GNU ddrescue (GPL-3, run as a separate process on the host —
same licence as the app, so even linking would be fine) images a dying drive
with retry logic, a map file, and reverse passes, and the app already knows how
to open the resulting image. The UX-above-everything shape: when reads fail
during a mount or copy, offer "copy everything that can still be read to a
file, then open that" as one button, with the map file surfaced as "N MB could
not be read". This turns the app's existing image support into a recovery
product. Cost: vendoring ddrescue (or implementing the retry/map loop in
Swift over the raw device — no licence question at all, moderate work), UI,
and honest progress reporting.

### Undelete — real, bounded

Nothing on macOS undeletes from FAT/exFAT/NTFS without third-party tools.
Already in the bundle: `ntfsundelete` ships inside ntfs-3g-progs (in the
guest today, unreached by any UI). To add: PhotoRec/TestDisk (GPL-2+) carve
FAT/exFAT/ext and raw media regardless of filesystem state. Both aggregate in
the guest. The win is real but the UX needs the guiding star applied hard:
recovered-file triage, not a forensics console. Cost: moderate tooling, large
UI care. `extundelete`/`ext4magic` are stale; treat ext undelete as
carve-based (PhotoRec) rather than promising inode recovery.

### Time Machine sparsebundles — the recovery case macOS abandons

The file's earlier "Encrypted DMG and sparse bundles" section already
overturns the §5 exclusion for the damaged case; the concrete mechanics
belong here. A sparsebundle is a folder: `Info.plist` (band size, total size)
plus `bands/N` files, each a slice of the disk at offset N×bandSize. A
read-only imago driver over that layout is a small, well-specified piece of
work in the same family as the VDI/VHD drivers already written here
(patches/imago-vdi-vhd-and-vhdx.patch), with one deliberate behaviour:
**a missing band reads as zeros and is reported**, where macOS refuses the
whole bundle. Inside is HFS+ (older TM) or APFS (newer) — which is why this
row depends on §1 Tier B's HFS+/APFS read-only story, or on the
unlock-and-hand-back-to-macOS route for bundles macOS can still attach once
the container layer is bypassed. Real win: "my backup won't open" is a
recovery request with no good answer today. Cost: the imago driver (small),
the filesystem driver dependency (the real cost), fixtures from deliberately
deleted bands.

### APFS snapshots, encrypted APFS, HFS+ that macOS refuses

- **Snapshots**: macOS mounts its own local snapshots; the gap is snapshots on
  an external or damaged container. apfs-fuse (GPL-2+) can mount a chosen
  snapshot read-only. Modest win, comes almost free once apfs-fuse is in the
  guest for the FileVault route the file already argues for.
- **Encrypted APFS on a drive macOS will not touch**: the chain is cryptsetup
  `fvault2` (CoreStorage-era FileVault) or apfs-fuse's own APFS-native
  decryption with the password, then read-only presentation. This is the §5
  FileVault section's route 1, and its audience is exactly the app's audience:
  a disk pulled from a dead Mac.
- **HFS+ macOS refuses**: fsck_hfs exists on macOS and is decent; the added
  value is only in the ddrescue-image-then-mount pipeline and in `hfsprogs`
  (APSL-2.0, aggregated) for a second repair opinion. Thin win; do it as a
  side effect of the kernel rebuild, not as a goal.

### FAT/exFAT write, HFS+/APFS write

No win exists: macOS writes FAT/exFAT natively and writes HFS+/APFS better
than anything Linux will ever ship (Linux HFS+ write is journalling-unaware,
linux-apfs-rw write is experimental). One sentence each: stand aside, as
SPECS.md §4 already does; the guest's exfat driver exists for the repair
ladder only.

---

## 5. Images and archives not covered

The existing sections already cover OVA (an archive with one stream-optimized
VMDK in it — the cheapest win in the document) and VHDX writing/dirty logs;
this section does not repeat them. The baseline table covers what is read
today. Everything else:

### Block-device image formats

| Format | Route | Cost, licence |
| --- | --- | --- |
| qcow2 backing files and external data files | Refused today by `Qcow2Header.namesAnotherFile` and the engine's own checks (SPECS.md §3), because an image choosing which other files the VM reads is an attack surface. The route that keeps the security property is the one the VMDK descriptor rule already demonstrates: allow a backing file that is a **plain name beside the image, resolved to a file still in that folder**, refuse everything else. Same rule, same code shape, applied to qcow2 and equally to VMDK `parentFileNameHint`, differencing VHD and VHDX parents. | imago backing-chain read support plus the rule in both layers (app probe and driver). Days-to-weeks per format family; no new licence. The refusal stays for anything absolute, dotted or symlinked out — SPECS.md's "checks are not relaxed" holds; they are *implemented for the safe subset* instead of standing in for it. |
| VMDK snapshot chains, VHD differencing, AVHDX | Same rule as above — a chain is repeated parent lookup. AVHDX additionally meets the VHDX log machinery the existing section covers; read-only chains first. | Moderate; the chain walk is bounded and each link is validated like every other header here. |
| Parallels HDD | qemu reads it (`parallels` driver); the **qemu-storage-daemon lever** (SPECS.md §5, scoped in the existing section) opens it without writing a driver. An imago driver is also feasible from the format's documentation if the qemu route stalls. | Rides the one qemu build; GPL-2 aggregated in the guest. |
| QED | Deprecated qemu format, qemu still reads it. Same lever. | Free once the lever exists. |
| Apple DMG, UDIF | Healthy DMGs macOS opens natively — stand aside (SPECS.md §5's reasoning holds for the healthy case). The recovery case: UDIF is a footer (`koly`) plus a block map (`blkx`) of zlib/bzip2/ADC/LZFSE/LZMA-compressed chunks. A read-only imago driver is very tractable (the decompressors are all in common libraries; LZFSE is Apple's own, github.com/lzfse/lzfse, BSD-3-Clause). Encrypted DMGs (v2, AES-128/256) have a published-enough layout with open readers to crib from (dmg2img, GPL-2; libdmg-hfsplus, GPL-3). | Driver: weeks. The payload then needs §1's HFS+/ISO handling or hand-back to macOS. Worth it only bundled with the sparsebundle recovery story. |
| sparsebundle, sparseimage | §4 covers sparsebundle (the Time Machine case). sparseimage (UDSP) is a single-file sparse format, same driver family, smaller audience. | Small, once the bundle driver exists. |

### CD/DVD images — the owner's question, answered directly

**An .iso already effectively works, and the right route is macOS, not the
guest.** Today an unrecognised extension is treated as raw and attached by
macOS (SPECS.md §1's image table; `DiskImage` attaches via hdiutil), and macOS
mounts ISO 9660, Joliet, Rock Ridge-adjacent hybrids and UDF natively,
read-only, multisession included. The guest kernel could not do it at all — no
iso9660, no udf (§1). What to actually build: recognise `.iso`/`.udf`
explicitly, hand to macOS deliberately with the §4-style on-screen verdict,
and add fixtures so the path is proven rather than incidental. Where the guest
does add value is the *damaged* disc image, via the ddrescue pipeline in §4.

The raw-but-not-quite formats need one small translation each, because they
carry 2352-byte raw sectors or vendor headers instead of 2048-byte data:

- **BIN/CUE**: parse the CUE, strip sync/header/EDC per 2352-byte sector — a
  tiny read-only imago driver, or convert via `bchunk` (GPL-2). Multi-track
  mixed-mode discs: expose the data track; audio tracks are not a filesystem.
- **NRG** (Nero): trailing footer describing tracks; converters exist
  (`nrg2iso`, GPL); for the common single-session case the payload is at a
  fixed offset.
- **MDF/MDS** (Alcohol): MDF is usually 2352-byte raw; same sector-strip
  driver handles it; `mdf2iso` (GPL) is the oracle.
- **CCD/IMG/SUB** (CloneCD): IMG is the same raw-sector payload.

One 2352→2048 mapping driver plus per-format header parsing covers all four.
Then hand the resulting 2048-byte image to macOS like any ISO.

### APK — the owner's question, answered directly

**An APK is a ZIP archive** (a JAR descendant): `classes.dex`, `resources.arsc`,
`AndroidManifest.xml` (binary XML), `lib/`, `assets/`, `META-INF/` signatures.
There is no filesystem inside and nothing to unlock; "opening" one means
presenting the archive's tree. So: yes, cheap, and it comes as one instance of
the archive architecture below, not as an APK-specific feature. Two honest
notes: macOS will not unzip it by double-click only because of the extension,
so the added value is browsing-in-place without extraction and without
renaming; and the contents people actually want to *read* (the manifest, the
dex) are binary formats — decoding those (apktool territory) is a
decompiler, not a mounter, and out of scope in one sentence: Lukotta shows
the files; it does not decompile them.

The Android *image* family, distinct from APK and very much block devices:
**Android sparse images** (`simg2img` logic, AOSP libsparse, Apache-2.0 — a
small read-only imago driver or a guest-side conversion), **super.img**
(dynamic partitions: `lpunpack`, Apache-2.0, splits it into partition images),
and **payload.bin** (OTA payloads: payload-dumper tools). What falls out of
each is ext4 or EROFS — both already in the guest kernel (§1). A factory image
unpacks to mountable read-only system images with only Apache-2.0 tooling
added. **iOS IPSW** is a ZIP of DMGs: the archive route opens the ZIP, the DMG
driver (above) reads the unencrypted payloads; encrypted payloads without
Apple's keys are unopenable — one sentence: that is the cryptography, and
nothing ships it.

### WIM/ESD/SWM

wimlib (wimlib.net; library LGPL-3, programs GPL-3) both extracts and — on
Linux — FUSE-mounts WIM images, ESD (solid LZMS) included, split SWM sets
included. Guest aggregation, FUSE is built in. This is the cleanest
archive-that-thinks-it-is-a-filesystem case: image count presented as
folders, read-only mount, done. NTFS capture/apply even gives a write story
later. Cost: one package build (musl/aarch64, the ntfsck pattern).

### Forensic images — E01/EWF, AFF4

libewf (LGPL-3) reads EnCase E01/EWFv2 and ships `ewfmount`, a FUSE tool
exposing the contained disk as a raw file — which then flows into the existing
raw path. AFF4: libaff4/pyaff4 (Apache-2.0). Both aggregate in the guest;
`ewfmount` inside the guest feeding the loop device is exactly the
qemu-FUSE-losetup shape SPECS.md §5 already approves of. The forensic audience
overlaps heavily with a recovery product's. Cost: two package builds, segment
sets (`.E01`–`.Enn`) handled by the same beside-the-file rule as VMDK extents.

### The architecture question: archives in Finder over NFS

For formats that are archives rather than block devices — APK, ZIP, 7z, tar,
WIM, IPSW — the right presentation is **a read-only FUSE mount inside the
guest, exported over the NFS route the app already has**, and the reasoning is
structural, not aesthetic:

1. The guest already turns "a tree of files" into "a Finder volume"; that
   pipeline is the product. An archive mounted by FUSE in the guest is
   indistinguishable from a filesystem to everything downstream — export,
   `nfc` handling, read-only enforcement, eject.
2. FUSE is built into the shipped kernel (§1), so it is pure userspace
   aggregation: **fuse-archive** (Apache-2.0, reads everything libarchive
   reads with random access) over **libarchive** (BSD-2-Clause) covers ZIP,
   7z, tar in every compression, ISO, cpio, RAR4/5 read-only, in one
   dependency with no licence friction anywhere. wimlib adds WIM. That is the
   whole stack.
3. On the Mac instead? FSKit is an open question the repo already tracks
   (TODO.md: broken for third parties on 26.1/26.2), macFUSE is a kext-consent
   regression for users, and plain extraction changes semantics (a 40 GB WIM
   should not need 40 GB free to look inside). The Mac-side route is worth
   revisiting only if FSKit comes good, and then for *healthy* archives at
   most — the same stand-aside logic as §4.
4. **Write support is refused on purpose.** Archive rewriting is
   delete-and-recreate; an interrupted write loses the archive, which
   violates the integrity story the rest of this app is built on
   (SPECS.md §6's ordering guarantees have no equivalent here).
   fuse-archive is read-only by design; that is the correct design.

One boundary decision to make deliberately: mounting an archive means the
*guest parses attacker-supplied archive structure* (today the guest parses
attacker-supplied filesystem structure, so this is the same trust posture, but
libarchive's decompressors are a larger surface than a filesystem driver —
it is the counterweight paragraph of the qemu section, again, and deserves
the same sentence in SPECS.md when it ships).

---

## 6. The legal framework

### The compatibility matrix

The three positions are the ones defined at the top of this file. "Yes" in
column 2 or 3 rests on the mere-aggregation / separate-programs analysis that
THIRD_PARTY_NOTICES.md already states for the GPL-2 kernel itself (GPLv2 §2
last paragraph, GPLv3 §5 last paragraph, and the FSF's FAQ on programs
communicating at arm's length). That analysis is decades-old universal
industry consensus, endorsed by the licences' own text — but note honestly:
no court has drawn the exact line, so it is consensus, not case law.

| Licence | 1. Linked into the GPL-3 app | 2. Aggregated in the guest image | 3. Separate process on the Mac |
| --- | --- | --- | --- |
| GPL-2.0-only | **No** — GPLv2-only and GPLv3 are mutually incompatible (FSF's own reading; settled consensus) | Yes | Yes |
| GPL-2.0-or-later | Yes, taken under GPLv3 | Yes | Yes |
| GPL-3.0-or-later | Yes | Yes | Yes |
| LGPL-2.1 | Yes — §6 linking permission, or upgraded via its §3 | Yes | Yes |
| LGPL-3.0 | Yes | Yes | Yes |
| MPL-2.0 | Yes — unless the files carry the "Incompatible With Secondary Licenses" notice | Yes | Yes |
| CDDL-1.0 | **No** — incompatible with every GPL | Yes as a userspace program; **contested** as a kernel module combined with Linux in one shipped image (§2 in full) | Yes |
| Apache-2.0 | Yes with GPLv3 (FSF position; the Apache-2/GPL-2 incompatibility matters for kernel code, not for this app) | Yes | Yes |
| APSL-2.0 (hfsprogs) | **No** — FSF-approved free but GPL-incompatible | Yes | Yes |
| BSD-2/3-Clause, MIT, Zlib, ISC | Yes | Yes | Yes |
| Proprietary with a redistribution grant | **No** | Yes on the GPL side (aggregation); the proprietary licence itself must permit this exact redistribution — read it each time | Yes, same caveat |

Two working rules fall out, and the repo already lives by both (TODO.md "Who
does what": "nothing gets linked into the app that cannot be"): position 2 is
where almost everything in this document goes, and the only components this
document proposes for position 1 or 3 are GPL-3-compatible anyway (ddrescue
GPL-3, libimobiledevice LGPL-2.1). One trap worth naming: position 3 stays
"separate" only while communication is at arm's length — pipes, files,
sockets, exec. Shared memory with shared data structures, or a plugin
interface, collapses it into position 1 (FSF FAQ; consensus).

### Patents and specifications, per format

| Format | Specification | Patent posture | Reading |
| --- | --- | --- | --- |
| exFAT | Published by Microsoft, 2019 | Microsoft made its exFAT patents available through the **Open Invention Network's Linux System Definition** (2019): https://opensource.microsoft.com/blog/2019/08/28/exfat-linux-kernel/ and https://openinventionnetwork.com/microsoft-readies-exfat-patents-for-linux-and-open-source/. The protection runs to the Linux System components — the guest's kernel driver and exfatprogs sit exactly there. | Industry consensus: safe in the guest. The app never implements exFAT itself. |
| NTFS | Never published | ntfs-3g has shipped an independent implementation for ~20 years without patent action, and Paragon's ntfs3 was accepted into mainline Linux (5.15), placing it inside the same OIN umbrella. | Consensus-by-decades. Lukotta implements nothing NTFS itself; it aggregates the two drivers everyone else ships. |
| VHD, VHDX | Published under Microsoft's **Open Specification Promise** | OSP is an irrevocable patent covenant for implementations of the covered spec | SPECS.md §9 already records this; settled enough. |
| ReFS | Not published | Unknown, active | Anything here would be clean-room reverse engineering with no covenant. One more reason §1 Tier C says "no route". |
| APFS | Apple published the *Apple File System Reference* (developer.apple.com), oriented to read access | No patent grant accompanies it | Reading APFS via apfs-fuse (independent, GPL) is the same posture as ntfs-3g's twenty quiet years, minus the years. Read-only keeps the exposure minimal; my reading, not settled. |
| HFS+ | Apple TN1150, published 2004 | None asserted in two decades of Linux hfsplus | Quiet. |
| UDF | Open OSTA/ECMA-167 standard | Standardised, patent-quiet | Safe. |
| ISO 9660 | ECMA-119, freely published | Ancient | Safe. |
| Blu-ray data (UDF 2.5/2.6) | Open | Safe for data discs | Safe. |
| **AACS** (Blu-ray video encryption) | Licensed by AACS LA under NDA + royalty | Not a patent problem — a **DMCA §1201 problem**: decrypting AACS without a licence is circumvention of an access control. *Universal v. Corley* (2d Cir. 2001) settled that trafficking in circumvention tools loses; that is as close to settled law as this table has. | **Do not ship AACS code, keys, or a "plays protected Blu-ray" feature. Ever.** §3 already routes around it. |

### Reverse engineering — where the app actually stands

Lukotta's own exposure is narrow because SPECS.md §9 already states the right
posture: every driver here is an independent implementation from published
documentation. On top of that:

- **US**: DMCA §1201(f) expressly permits circumvention and independent
  reverse engineering "for the sole purpose of interoperability"; *Sega v.
  Accolade* (9th Cir. 1992) and *Google v. Oracle* (S. Ct. 2021) anchor the
  fair-use side; *Chamberlain v. Skylink* (Fed. Cir. 2004) and *Lexmark v.
  Static Control* (6th Cir. 2004) cabin §1201 to access controls that
  actually guard copyrighted works. Unlocking BitLocker, LUKS, tcrypt or
  FileVault **with the owner's own passphrase** is not circumvention in any
  reading the courts have endorsed — the user is the authorised party
  decrypting their own data. My reading, widely shared; not litigated in this
  exact shape; the one place in this section where a real lawyer's memo would
  be cheap insurance is this sentence plus the ZFS route-3 decision.
- **EU**: Software Directive 2009/24/EC Art. 5(3) protects observing and
  studying a program, Art. 6 permits decompilation for interoperability, and
  *SAS Institute v. World Programming* (CJEU C-406/10) holds functionality
  and file formats are not copyrightable as such. Independent
  implementations of on-disk formats are squarely inside this. Settled law
  in the EU to an unusual degree.

### Trademarks — verified from the repo

TRADEMARKS.txt and build-app.sh confirm the position stated: **builds are
unbranded by default** — `LUKOTTA_BRANDING` unset produces "Drive Unlocker"
under `com.example.driveunlocker` with placeholder art (build-app.sh lines
35, 88–89, 608–611) — because the Lukotta name, wordmark and logo are
trademarks withheld under GPLv3 §7(e), while `LUKOTTA_BRANDING=official`
exists so a published release can be verified against source without granting
distribution rights in the mark. What this implies for everything new in this
document: every added format drags in someone else's mark — BitLocker and
ReFS (Microsoft), **ZFS (an Oracle trademark)**, Blu-ray (BDA), iPhone
(Apple), Android (Google) — and the discipline THIRD_PARTY_NOTICES.md already
applies ("names them to state what it works with") must extend to each:
nominative use in descriptions, never in the app's name, icon, or anything
that implies endorsement. "Opens ZFS volumes" is fine; a ZFS logo on a
button is not.

### The SBOM and notices obligation the repo imposes on itself

The machinery, verified in scripts/: `guest-sbom.py` writes a committed
CycloneDX SBOM from the *shipped* package database (with SrcName preserved so
Trivy actually matches advisories — its own comment records that failure
mode); `generate-notices.sh`/`generate_notices.py` regenerate
THIRD_PARTY_NOTICES.md from the same database and refuse to run from anything
but what ships; `trim-image.py` writes `removed-packages.txt` so the notices
can state removals from data; `collect-sources.sh` and
`collect_alpine_sources.py` assemble the corresponding source published with
every release, per the GPLv3 §6(d) same-place offer the notices declare; and
`vendor/engine.lock` pins and checksums every upstream. The obligation this
creates for every component this document proposes: it enters the lock
(pinned, checksummed), the guest package DB or the host component table, the
SBOM, the notices, and the corresponding-source archive — and for anything
built from source (the ntfsck pattern), the revision file rides beside the
binary as `build-ntfsck.sh` already does. This is not overhead to minimise;
it is the reason §2's route 3 would even be *arguable* — the project's
compliance story is complete and demonstrably automated.

### Where a real lawyer is needed, in one list

1. Before shipping zfs.ko inside the guest image (§2 route 3) — and only that
   route; routes 1 and 2 need none.
2. Before shipping any proprietary-with-redistribution driver in the guest
   (the ReFS temptation).
3. A short memo blessing the "owner's own passphrase is not circumvention"
   reading if the tcrypt/FileVault features draw legal attention.
4. Nothing else in this document: the rest is either settled, or the same
   posture the project already ships under.

---

## The build order

Ranked by coverage per unit of work. Each line: what, then why it is where it
is.

1. **Open the VMDK inside an OVA** — one tar read, no new component; the
   file's own "cheapest win" (existing §, SPECS.md §5).
2. **Fix the RAID claimed-but-unopenable defect** — it is a live defect with
   a user consequence, the engine side is already proven, only app-side
   grouping remains (§3).
3. **The tcrypt rung** — VeraCrypt/TrueCrypt with zero new dependencies; the
   component ships today, unreachable (existing §).
4. **Tier A filesystems: F2FS, then squashfs + EROFS, then bcachefs** —
   kernel drivers already ship; tools are in Alpine; each is a probe case
   plus a package (§1).
5. **fsck.exfat + fsck.fat repair ladder** — the most common broken-media
   case the public has, two packages, ladder shape already exists (§4).
6. **Archive mounting via fuse-archive/libarchive (+ APK recognition)** —
   one clean-licence dependency buys APK, ZIP, 7z, tar, RAR-read, IPSW-outer;
   answers the owner's APK question (§5).
7. **.iso/.udf recognised and handed to macOS deliberately, with fixtures**
   — the owner's CD/DVD question; mostly verdict UX over a path that already
   exists (§5).
8. **ddrescue imaging pipeline** — turns existing image support into the
   recovery feature nothing on macOS has; licence-trivial (§4).
9. **qemu-storage-daemon with fuse3 in the guest** — one build unlocks
   Parallels, QED, iSCSI, NBD and a long tail of read paths; already scoped
   in SPECS.md §5; needs the trust-boundary paragraph written (§3, §5).
10. **Parent/backing chains with the beside-the-file rule** (qcow2 backing,
    VMDK chains, VHD differencing, AVHDX read-only) — moderate driver work,
    closes the whole "names another file" family safely (§5).
11. **NTFS completeness: WOF system-compression plugin, ntfsdecrypt wiring,
    dedup detection** — small additions to the flagship filesystem (§1).
12. **wimlib and libewf in the guest** — WIM/ESD and E01 open two whole user
    communities for two package builds (§5).
13. **The kernel rebuild** — UDF-on-disk, HFS+, NILFS2, JFS, ReiserFS,
    minix at a config line each, plus the NBD option SPECS.md wants; one
    sizeable piece of infrastructure, many small doors (§1).
14. **sparsebundle driver + UDIF/DMG read-only driver** — the Time Machine
    and damaged-DMG recovery stories; depends on 13 (or apfs-fuse) for the
    payload (§4, §5).
15. **FileVault 2 unlock + apfs-fuse read-only** — the recovery case for
    dead Macs; the file's earlier section prefers unlock-and-hand-back where
    macOS can take it (existing §, §1).
16. **FreeBSD guest for ZFS (and UFS)** — the clean-licence ZFS route;
    largest single engineering item here, which is why the legally spotless
    option ranks last among the things worth doing at all (§2).
17. **Not ranked because no route or no audience**: ReFS, AACS, OPAL-on-Mac,
    520-byte sectors, LTFS, MTP-as-filesystem — each has its one-sentence
    verdict and nearest-working-thing in §1 and §3.

*End of the coverage analysis. Baseline read 2026-09-04; guest inventory read
from vendor/engine/alpine/rootfs.tar.gz (kernel 6.12.62 modules.builtin) and
vendor/.cache/source/anylinuxfs-0.19.0 the same day.*
