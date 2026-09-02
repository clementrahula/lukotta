# Specifications

What Lukotta opens, how it opens it, and what it does not.

Lukotta hands a drive or a file to a Linux virtual machine, mounts it there, and
re-exports it over NFS so that Finder sees an ordinary volume. Lukotta can
therefore open what Linux can mount, provided the bytes reach Linux in a form it
recognises.

---

## 1. What can be opened

### Filesystems

| Filesystem | How it is mounted | Notes |
| --- | --- | --- |
| NTFS | `ntfs3`, falling back to `ntfs-3g` | The in-kernel driver refuses a volume Windows left dirty; the userspace one mounts it, so both are attempted in that order |
| ext2, ext3, ext4 | in-kernel | |
| btrfs | in-kernel | |
| XFS | in-kernel | |
| exFAT | not mounted in the guest | Handed to macOS, which reads and writes it natively. See §4 |
| FAT | not mounted in the guest | macOS reads it natively |
| APFS, HFS+ | not mounted in the guest | macOS reads them natively, and the guest has no driver for either |

The guest is an Alpine image of 66 packages carrying `ntfs-3g`, `btrfs-progs`,
`e2fsprogs`, `cryptsetup` and `lvm2`. A filesystem outside that list cannot be
mounted.

### Encryption

| Encryption | Opened | Notes |
| --- | --- | --- |
| BitLocker | Yes | Unlocked by `cryptsetup bitlkOpen` in the guest |
| LUKS1, LUKS2 | Yes | Unlocked by `cryptsetup open` |
| FileVault 2 | No | macOS opens it natively. See §5 |
| VeraCrypt, TrueCrypt | No | cryptsetup carries `tcrypt`, which is not currently reachable. See §5 |
| Encryption applied by an image format | No | qcow2 and VMDK can encrypt their own contents. Encryption *inside* an image, as a LUKS or BitLocker volume, is opened |

### Volume managers

LVM volume groups are discovered and their logical volumes opened, including a
group inside an encrypted container. Linux software RAID is recognised by the
engine.

### Disk image formats

| Format | Read | Written | How |
| --- | --- | --- | --- |
| Raw (`.img`, `.dmg`, and any unrecognised extension) | Yes | Yes | Attached by macOS, then mounted in the guest |
| qcow2 | Yes | Yes | Read and written by imago's own qcow2 driver |
| VMDK, flat (`monolithicFlat`, `twoGbMaxExtentFlat`) | Yes | Yes | A text descriptor beside one or more raw extents |
| VMDK, sparse (`monolithicSparse`, `twoGbMaxExtentSparse`) | Yes | Yes | Grain directory, grain tables, grains |
| VMDK, stream-optimized | Yes | No | Deflated grains, each behind a marker. This is what an OVA carries; it is written in one pass and cannot be changed in place |
| VDI, dynamic and fixed | Yes | Yes | VirtualBox's format |
| VHD, fixed | Yes | Yes | The raw disk with a 512-byte footer after it |
| VHD, dynamic | Yes | Yes | Blocks listed by an allocation table |
| VHDX | Yes | **No** | Header pair, region table, metadata region, allocation table. See §5 |
| VMDK snapshot chains | No | | Names a parent file. See §3 |
| VHD, differencing | No | | Names a parent file. See §3 |
| VHDX with a parent | No | | Names a parent file. See §3 |
| VHDX with a log that is not empty | No | | See §5 |
| Sparse bundles, encrypted DMG | No | | macOS opens both natively. See §5 |

The VMDK, VDI, VHD and VHDX drivers were written here for imago, the crate that
reads image formats for the engine. See `patches/README.md`.

An image whose format cannot be written is opened read-only from the start: the
application knows which container it holds before anything is mounted, and asks
for a read-only mount whatever the person chose. The device the guest is given
is marked read-only as well, so nothing can reach the file through it either.

An image whose *file* cannot be written takes the same course, decided later:
one on a read-only volume, a locked file, a card with its write-protect switch
set. The open for writing fails, the file is opened for reading instead, and
the device is marked read-only. Failing the mount outright would leave no way
into a file that could be read.

---

## 2. How it works

Four layers carry a disk image from a file name to a mounted volume, each of
them patched here:

    file extension  →  anylinuxfs DiskFormat  →  a format number  →  krun_add_disk2
                    →  krun-devices ImageType →  imago driver

libkrun passes the format number straight through, so it needs no modification.
The engine is built from pinned, checksummed upstream source with the patches in
`patches/` applied; `scripts/build-engine.sh` does this, and
`engine/anylinuxfs/PATCHES` records which patches a given build carries. The
application reads that file and reports by name any format the engine it was
built with cannot open.

Two paths lead to a mounted volume:

**A physical drive** is unlocked and mounted in the guest, then re-exported over
NFS. Reading a raw disk device requires the privileged helper.

**A disk image** is opened without privilege. A raw image is attached by macOS
first; every other format is handed to the engine as a path, which the engine
reads itself, attaching nothing. The mount appears under `~/Volumes` rather than
`/Volumes`.

Either can be opened read-only, which is set in two places. `-o ro` mounts the
filesystem read-only inside the guest, and `ro` among the NFS options mounts it
read-only on this Mac, which is the half Finder reads. The export itself is left
as the engine writes it: `--nfs-export-opts` cannot be combined with
`--ignore-permissions`, and replacing the export would discard what that flag
sets, which is what makes the files readable by whoever opened the drive.

A drive that refuses to be written to is mounted read-only rather than left
closed. Every attempt in the generated script is followed by the same attempt
read-only, and the script writes a `read-only` stage marker when one of those
succeeds, so a drive is never described as writable when it is not.

Read-only comes last. Where every writable attempt failed but the transcript
shows the machinery slipped, a broken pipe or an image the last virtual machine
had not finished releasing, all of them are made again before the read-only ones
are reached. A Microsoft drive has two, `ntfs3` and `ntfs-3g`. Retrying only the
first re-ran the driver that had already refused for a real reason, so the drive
stayed read-only for the session and the explanation blamed the filesystem for a
fault in the machinery.

An attempt has an end on all three routes. The application stops waiting after
eight minutes, the privileged daemon keeps the same deadline for the mount it
runs itself, and the generated script keeps a shorter one on top of both and
ends the engine it started. A privileged attempt belongs to root, so killing the
shell from the application reaches the shell and not the engine under it: that
engine went on mounting and produced a drive in Finder minutes after somebody
had been told it could not be opened, with nothing left to eject it.

---

## 3. Images that name other files

libkrun's own header records that formats other than raw may reference other
files, which libkrun then opens. A qcow2 backing file, a VMDK descriptor listing
its extents, a differencing VHD or a VHDX naming its parent are all such
references. An image can therefore determine which other files the virtual
machine reads.

Every such image is refused before the engine is given the path:

| Format | Rule |
| --- | --- |
| qcow2 | Refused if it names a backing file or an external data file |
| VMDK | Every extent must be a plain file name situated beside the descriptor: nothing absolute, nothing containing a separator, no `..`. That is what VMware writes. The name is then resolved, and the file it leads to must still be in that folder, so a symbolic link out of it is refused as a path out of it would be. An extent of any type but ZERO that names no file is refused, having described part of a disk that is nowhere. A `parentFileNameHint` is refused |
| VHD | A differencing image is refused |
| VHDX | An image naming a parent is refused |
| VDI | Cannot name another file; its data is always its own |

The drivers refuse these images as well, so the rule holds in both layers. Disk
images are also opened without privilege, which limits the reach of any such
reference to what the person who opened the file could already read. The checks
are not relaxed as further formats are added.

---

## 4. What is handed to macOS instead

An exFAT image is attached by macOS and left mounted there. macOS reads and
writes exFAT natively, so routing it through NFS would add a layer and take the
volume out of Finder's control. The application says so on screen, the volume
appearing in `/Volumes` rather than `~/Volumes`.

The same reasoning applies to the drive list: a disk macOS already reads is
listed with that as its verdict, and not offered for opening.

---

## 5. What is not supported, and why

### FileVault 2

macOS opens it natively, and the guest has no HFS+ or APFS driver, so a volume
unlocked there could not then be mounted. cryptsetup's `fvault2` handler exists
and leads nowhere without a filesystem driver behind it.

### Encrypted DMG and sparse bundles

macOS opens both natively and integrates them with Keychain and Finder.

### VeraCrypt and TrueCrypt

cryptsetup carries an independent `tcrypt` implementation, and it is in the
guest already. It is not reachable from the application, since the engine
decides what to unlock from what `blkid` reports, and a TrueCrypt volume has no
signature to report: the header is indistinguishable from random data by design.
Opening one requires the person to state that a device holds a TrueCrypt volume
and to supply the passphrase. Adding it would require an interface for that
statement. No new dependency is involved.

### Stream-optimized VMDK inside an OVA

The format itself is read. An OVA is a tar archive containing a descriptor and
one of these images, and Lukotta does not extract archives. Extract the `.vmdk`
and open that.

### Writing to a VHDX

VHDX is read and never written. The format requires every change to its
allocation table or its metadata to be written into its log first, so that a
writer interrupted part-way leaves a file the next reader can repair. A writer
must also stamp a new write identifier into one of the two headers, each of
which carries a sequence number and a CRC-32C. A writer that skips the log leaves no trace that anything was interrupted, and
that failure cannot be detected afterwards. Writing the log is therefore a
precondition for writing a VHDX at all, and it is not written here.

So a VHDX opens read-only, the device the guest is given is marked read-only,
and the screen offering to open one says so before anything is mounted.

### VHDX with a log that is not empty

An image that was not shut down cleanly keeps its most recent state in its log.
Replaying that log is a write, which the paragraph above rules out. Reading the
file without replaying it returns data older than the disk last held. The image
is therefore refused by name, and the message states the remedy: open it once in
the virtual machine it belongs to, which empties the log.

This could be done without writing to the file. imago's `readv_special()` allows
a driver to serve bytes itself, so a log could be replayed into memory and
applied to the structures the driver has already read. The obstacle is
verification: a genuinely dirty image is difficult to obtain, and an image
written by the same author as the reader tests only that they agree with each
other.

### qemu in the guest

QEMU's block layer has written all of these formats for years. Borrowing it was
measured:

- `CONFIG_BLK_DEV_NBD` is not set in the kernel libkrunfw builds, and it is not
  available as a module either, so `qemu-nbd` has nothing to attach to. Turning
  it on means building and shipping a kernel of our own.
- `CONFIG_FUSE_FS=y` and `CONFIG_BLK_DEV_LOOP=y`, so a FUSE export could be
  attached with `losetup`. Alpine packages `qemu-storage-daemon` in its
  `qemu-img` subpackage, but builds it without `fuse3`, so the export type is
  absent. Using it means building QEMU's tools for aarch64-musl and shipping
  them in the guest, and exposing the image file to the guest, which never sees
  it today.

Both remain open. Neither is needed for the formats above, and `qemu-img` is
used as the oracle the drivers are tested against instead.

---

### A symbolic link whose target is not plain ASCII

A volume is served to Finder over NFS, and the mount carries macOS's `nfc`
option: names are converted to composed form on the way to the server, which is
what makes a name written on a Linux volume come back the way it was typed.

The same option refuses a symbolic link whose target contains both a directory
separator and a character outside ASCII. `symlink(2)` answers EINVAL, and a link
of that shape already on the drive cannot be followed: `readlink` returns the
right text, and opening through it fails. An ASCII target is unaffected, in a
directory or at the root, and hard links are unaffected entirely.

Both halves belong to the client rather than to this application or the drive:
the same volume mounted without `nfc` takes such a link and follows it. The
option stays, because names are what every volume is full of and this shape of
link is rare, turning up in archives written on a system in another language.

## 6. Where the drivers came from

imago read raw, qcow2 and flat VMDK, and wrote only qcow2 and raw. Everything
else in the table above was added in `patches/imago-*.patch`:

| Driver | Shape | Written |
| --- | --- | --- |
| VDI | Header, then a flat block map of 32-bit indices | Yes |
| VHD | Trailing footer; blocks listed by an allocation table | Yes |
| VMDK, sparse | Grain directory, grain tables, grains | Yes |
| VMDK, streamed | The same, deflated behind markers | No, written in one pass |
| VHDX | Header pair, region table, metadata region, allocation table | No, see §5 |

Every driver validates each value before relying on it: block sizes must be
powers of two, maps are bounded to a size a real disk could require, and every
entry must lie within the file. A damaged or hostile image cannot direct a
driver to read an unrelated part of the file and present it as the disk.

### How a write finds room

Each format grows the same way, and the order of the writes is what an
interrupted one depends on.

| Format | Where a new block goes | Linked in by |
| --- | --- | --- |
| VHD, dynamic | Over the trailing footer, which moves to the new end | The allocation table entry, written last |
| VDI | After the last block in the file | The count of allocated blocks, then the map entry |
| VMDK, sparse | After the end of the extent | The grain table entry, and the redundant table beside it |

In each case the space exists before anything points at it, so a write
interrupted part-way leaves an image holding what it held before, with unused
space at the end. Nothing is written into the new space: it lies past where the
file ended, so it already reads as zeroes. A fixed VHD, a static VDI and a flat
VMDK need none of this, every byte of the disk already being in the file.

This survives the writer stopping: the app quit, the virtual machine killed,
the engine crashed. It is ordering within the process rather than a barrier
through to the drive. Each ordering point is marked with a flush, and a flush
on a plain file has nothing of its own to write out, so what macOS has accepted
and not yet written it may still write in any order.

Durability across a power cut comes from the guest. A filesystem inside the
virtual machine issues its own barriers; each reaches the block device as a
flush request, and the device answers one by syncing the file. An ext4 or NTFS
journal is therefore as durable here as on a real disk, with the same caveat:
what was written since the last barrier is what a power cut can take.

### How it is checked

`qemu-img` is the oracle, having written these formats for years. The tests in
`src/write_tests.rs`, carried by the imago patch, create an image with
`qemu-img`, write to it through the driver, then have `qemu-img` check the image
and convert it to raw, comparing every byte against a model kept beside the
writes.

They cover the first block, a write crossing two, one aligned to nothing, a
second write over ground already allocated, several blocks at once, the last
byte of the disk, filling an image completely, a grain directory with a gap in
it, two hundred randomly placed writes per format from a fixed seed, and a qcow2
holding an internal snapshot, whose shared clusters have to be copied before
they are written.

Reading was verified the same way and in both directions: images written by
`qemu-img` read back byte for byte identical to the raw disk they were made
from, and `qemu-img compare` reads the images the scripts under `scripts/`
produce and finds them identical. Every format then mounts and ejects through
the application in the end-to-end run, which uses the images those scripts
write, so the application's own test suite requires neither qemu nor
VirtualBox.

---

## 7. What is proven, and how

Every claim below was produced by running it on an Apple Silicon Mac against
real hardware or a real fixture, and the script that produces it is named. A
claim with no script behind it says so.

The corpus throughout is `scripts/copy-torture.sh`: 2024 files chosen for the
shapes a filesystem bridge breaks on. Names NTFS keeps as UTF-16 and macOS hands
over decomposed, names at the 255-byte limit, trailing dots Windows refuses,
sizes exactly on and either side of the block and transfer boundaries, a sparse
gigabyte, empty files, two thousand small files where metadata dominates, and a
directory deep enough to make the path long. Every byte is read back and
compared.

### Filesystems and containers

| Claim | Evidence | Script |
| --- | --- | --- |
| NTFS/BitLocker reads and writes correctly | 13 GB through Finder onto a real BitLocker drive, 26/26 files byte-identical; 1 GB and 2 GB repeats; 3000 files in nested folders byte-identical | `finder-copy-cycles.sh` |
| ext4 | corpus: 2024 identical, 0 differing, 0 missing | `copy-torture.sh` |
| btrfs | corpus, inside LUKS: 2024 identical | `copy-torture.sh` |
| XFS | corpus: 2024 identical | `copy-torture.sh` |
| LUKS2 → btrfs | corpus: 2024 identical | `copy-torture.sh` |
| LUKS2 → ext4 | corpus: 2024 identical | `copy-torture.sh` |
| LUKS2 → XFS | corpus: 2024 identical | `copy-torture.sh` |
| LUKS2 → LVM → btrfs | corpus: 2024 identical; container opens every logical volume at once, all writable, concurrent copies into two byte-identical | `copy-torture.sh`, `lvm-lock-rule.sh` |
| exFAT is handled by macOS, not the guest | attached and checked: mount table shows `exfat, local`, through FSKit, no microVM involved | manual, recorded in `make-format-volumes.sh` |
| BitLocker unlock survives a copy cycle | drive ejected and unlocked again, 26/26 identical through the new mount | `finder-copy-cycles.sh` |

### Disk images

`scripts/e2e.sh` drives the built app through open, unlock, list, relaunch and
eject for every image format, including the ones that must be refused. **866 of
866 steps pass.** Fixtures built and exercised: qcow2, encrypted qcow2, VDI, an
ancient-format VDI, VHD, dynamic VHD, VHDX, a dirty VHDX, a VHDX with a parent,
monolithicFlat VMDK, a VMDK reaching outside its directory, sparse VMDK and
stream-optimized VMDK.

Reading is exercised heavily. **Writing to qcow2, VMDK, VDI and VHD is not
thoroughly tested**, and §6 says why the drivers are new.

### Crash and integrity vectors

`scripts/integrity-vectors.sh`, run against XFS. Ten of eleven pass:

| Vector | Result |
| --- | --- |
| a copy killed partway | 40 whole files, 0 corrupt |
| the volume still takes a write afterwards | passes |
| unmounted under load | mounts and reads afterwards |
| what was written before the unmount | survives |
| a full volume | answers with an error in 7 s rather than hanging |
| three open/close cycles | 3 of 3 |
| permissions | everything written is readable by whoever wrote it |
| two writers and a reader at once | 24 compared, 0 differing |
| the filesystem after the machine is killed mid-write | comes back |
| **fsynced data after the machine is killed** | **fails, see §8** |
| the volume takes a write again after that | passes |

### Repair of dirty NTFS

`scripts/corrupt-corpus.sh` runs the app's real mount ladder against 83
deliberately corrupted NTFS images published by the ntfsprogs-plus project:
boot sectors with impossible geometry, MFT records missing attributes, corrupted
attribute lists, orphaned inodes, cluster runs past the end of the disk, and an
image taken from a real USB unplug.

**83 cases: 68 opened at a driver rung, 15 refused, 1 refusal that also wrote to
the volume.** The check that matters is that a refusal leaves the image
byte-identical: a driver that writes to a damaged filesystem before giving up
turns a recoverable disk into an unrecoverable one.

Proven on real hardware as well, three times unattended: the author's BitLocker
drive was left dirty with `$MFTMirr` behind `$MFT` by abrupt machine kills, and
each time the app repaired it on the next open, reporting `Correcting
differences in $MFTMirr record 3...OK`, and mounted it writable with every
folder and file count unchanged.

### Concurrency and footprint

`scripts/eight-gig-pressure.sh`. Thirteen volumes open at once, twelve NTFS
fixtures plus a real BitLocker drive, all writable, **2378 MB resident across
every engine process**, 68% of memory free, home directory listing 17–24 ms.

Under artificial memory pressure (8 GB of incompressible ballast held, so what
remains is roughly an 8 GB Mac's share): all twelve fixtures written and read
back, home listing 16–20 ms, and the machines' resident total *fell* from
1545 MB to 554 MB. Most of what a machine holds is page cache it gives back, so
a dozen volumes do not cost a dozen times a fixed price.

This was measured on a 16 GB Mac16,12 made to feel like an 8 GB one. Not on an
8 GB M1.

### The stall that started this

| | before | after |
| --- | --- | --- |
| 13 GB Finder copy onto a BitLocker drive | died at 84% with error 100060, four files at zero length | completes, 26/26 byte-identical |
| requests past 5 s | 10 "not responding" notices | 4 slow requests, 0 notices |
| root cause | `timeo` was set and inert | `dumbtimer` makes it the interval that is actually used |

---

## 8. Known defects

Measured, reproducible, and not yet fixed. Each names what is known about the
cause.

### A file with a resource fork is dropped, and the copy reports success

Copying a file carrying `com.apple.ResourceFork` onto a Lukotta volume creates
nothing. `ditto` on a single file exits 1 and prints one line; `ditto` on a
folder exits **0** with the file simply absent, and Finder copies through the
same machinery.

Narrowed to one refused call:

```
printf data > /Volumes/DRIVE/f.bin                    ok
printf x    > /Volumes/DRIVE/._f.bin                  ok
printf x    > /Volumes/DRIVE/f.bin/..namedfork/rsrc   not writable
xattr -w com.apple.ResourceFork ... f.bin             [Errno 22] EINVAL
```

Every other extended attribute is accepted and stored in an AppleDouble file
beside the original. `com.apple.ResourceFork` alone is refused by the macOS NFS
client. It is not the filesystem and not the tool: the same command onto local
APFS keeps the fork, and onto an XFS image over the same stack it fails exactly
as it does on NTFS. No mount option reaches it. `scripts/xattr-forks.sh`.

### fsync does not survive a killed machine

Data an application was told had been committed is lost if the microVM is killed
outright. On an image: 4 MB written with `dd conv=fsync`, machine killed,
returns full length with exactly 32768 bytes of holes at offset 0, identically
on XFS and ext4, every run. On the author's physical BitLocker drive the file is
**absent entirely**.

**The cause, found 2026-09-02: nothing in the stack flushed the drive.**
Measured on macOS 26, on a target opened for writing:

| target | `fsync` | `F_FULLFSYNC` | `DKIOCSYNCHRONIZECACHE` |
| --- | --- | --- | --- |
| device node | ok, and does nothing | ENOTTY | ok |
| regular file | ok | ok | ENOTTY |

The two calls are exact complements, and the first column is the trap: `fsync`
on a device node returns success having done nothing. imago's `sync()` offered
only those two, `fsync` under libkrun's `relaxed_sync` (which macOS gets
unconditionally, `libkrun-1.19.3/src/lib.rs:789`) and `F_FULLFSYNC` otherwise,
which a device refuses. So a raw device could not be flushed by either branch,
and both reported that it had been.

That also explains the split the earlier readings showed. An image handed to the
engine is a regular file, where `fsync` is real:

| Target | After the machine is killed |
| --- | --- |
| NTFS image | survives, byte-identical |
| XFS and ext4 images | present, 32768 bytes of holes at offset 0 |
| NTFS physical drive | absent entirely |

NTFS is the most durable of the three on an image and the only total loss on a
drive, so the filesystem was never the variable.

`patches/imago-flush-device-nodes.patch` adds the device branch, decided at open
rather than stat-ed on every barrier, tolerating a device that answers that it
has no cache to flush. Without that tolerance every barrier becomes an I/O error
and nothing mounts. **Not yet proven by measurement:**
`scripts/kill-durability.sh` is written and its run is still blocked on the
engine's lock file. What the ioctl costs a copy is also unmeasured.

Ruled out along the way, each by measurement:

- **The engine's block cache.** `CacheType::auto()` returned `Unsafe` for any
  `/dev/rdisk*` path, and `Unsafe` answers the guest's flush with a no-op.
  Patched (`patches/krun-devices-raw-device-flush.patch`) so every path gets
  `Writeback`. The symptom was unchanged, because the flush it now performs was
  the `fsync` above.
- **The NFS export.** vmproxy builds
  `{rw|ro},no_subtree_check,no_root_squash,insecure` with no `async`, so nfsd is
  in its default `sync` mode.
- **The guest mount options.** `dirsync` was applied, confirmed in the
  transcript, and changed nothing. Reverted, because synchronous directory
  updates cost every many-small-file copy something.
- **The export's write gathering.** `no_wdelay`, spelled out as an explicit
  `--nfs-export-opts` because the engine refuses that flag together with
  `--ignore-permissions`, confirmed live on the running engine. The 8 MB was
  written, fsynced and verified byte-for-byte on the mount before the kill, and
  was still absent afterwards. Reverted.
- **ntfs3's own fsync path**, which an earlier reading blamed. See the table
  above.

`-o sync` would mask it and is refused: it makes every write synchronous.

A normal eject is safe. `EngineProcesses.stop` sends SIGTERM and waits up to
twenty seconds. SIGTERM flushes cleanly, 100 MB surviving with the machine
exiting in 0.34 s, and it never escalates while a machine is still running.

### Listing the folder being copied into is slow

While a large copy runs, that one folder takes several seconds to enumerate;
occasionally much longer. Measured through `getattrlistbulk(2)`, which is what
Finder uses rather than `readdir`: **median 8.42 s, worst 34.67 s**.

It is the NFS layer, established by timing the same directory from both sides in
the same seconds during the same copy:

```
readdir over NFS, from the host     median 7.11s   worst 90.05s
readdir inside the guest            median 0.01s   worst  2.79s
```

Not the device: a GETATTR of a file *inside* the stalling directory is answered
in 0.03 s off the same drive. Not the filesystem: NTFS on an SSD behaves like
ext4 on an SSD. Not creates: a directory receiving 3000 file creations lists in
0.04 s. Seven settings were measured:

| Setting | Result |
| --- | --- |
| nfsd threads 8 → 32 | worse on all four numbers |
| ntfs3 → ntfs-3g | worse, and spreads the stall to quiet folders |
| `nr_requests` 256 → 32 | median worse |
| `rdirplus` → `nordirplus` | median worse |
| **wsize 131072 → 32768** | **worst 90.05 s → 16.56 s, copy faster. Kept.** |
| wsize 32768 → 16384 | better median, worse tail, slower copy |
| `acdirmin` 5 → 30 | nothing, and slower |

The tail was reachable and the median is what NFS costs here. Removing it means
removing the NFS client from the path, which means FSKit.
`scripts/readdir-under-copy.sh`, `scripts/bulk-list.c`.

### RAID arrays are not yet offered by the app

`DiskWatcher.ourContent` includes the Linux RAID type GUID, so macOS stops
offering to initialise an array member. What is missing is the app constructing
the `raid:<devA>[:<devB>...]` identifier; `assemble_raid` is set only on the
`raid:` and `lvm:` branches of `cmd_mount.rs`, so handing the engine a member's
device path assembles nothing.

The layer underneath works. A two-disk RAID1 built with `mdadm --create`,
carrying btrfs, assembles and mounts through `raid:a.img:b.img`, and a copy onto
it reads back **4 of 4 byte-identical**. `mdadm` ships in the guest.

One trap looked exactly like the engine being unable to assemble RAID at all.
`anylinuxfs shell` truncates an image to the last byte written, and a RAID
superblock records the device size at creation, so a truncated member answers
`Device /dev/vda is not large enough for data described in superblock` and the
array will not assemble. `make-test-volumes.sh` restores the length, as `e2e.sh`
does.

### Writing to a virtual machine image is not thoroughly tested

Reading is exercised heavily: every image format goes through open, unlock,
list, relaunch and eject in `e2e.sh`, and the ones that must be refused are
refused. Writing is not. The qcow2, VMDK, VDI and VHD write paths are drivers
written for this project (§6), checked against `qemu-img` when the engine is
built from source, which is not the same as having been in use. Open an image
read-only to copy files out of it, or keep a backup.

A VHDX is read-only by design and is not affected.

### ZFS is not supported

The guest kernel carries no ZFS: the `zfs` and `zfs-libs` packages are trimmed
and `lib/modules/*/fs/zfs` is removed by path, because no package owns those
files and dropping the packages alone left the modules behind. Whether to carry
it is an open question with a licence dimension, ZFS being CDDL, as much as a
size one. Neither offered nor tested.

### Two routes into an image, and they differ

Not a defect. Recorded because it has already cost one wrong diagnosis. A
whole-disk image appears in the drive list under the file's own path; a
partitioned image is attached, and its partition appears under a real volume
UUID. Code waiting for a row identified by the file path waits forever for a
partitioned one, which reads as the app being unable to open it. `e2e.sh` passes
866 of 866 steps with the two routes distinguished.

---

## 9. Licensing

anylinuxfs is GPL-3.0-or-later, as is Lukotta. imago is MIT and krun-devices is
Apache-2.0, both compatible with it. The three driver files added to imago are
MIT, so that they may be offered upstream. Modified files carry the notices
their licences require. `patches/README.md` sets this out in full.

Format specifications are published for implementation. VHD and VHDX are covered
by Microsoft's Open Specification Promise, VMDK by VMware's published
specification, and VDI by VirtualBox's source and the documentation derived from
it. Each driver here is an independent implementation written from published
documentation.

Names are other parties' trademarks. Describing what Lukotta opens is nominative
use; putting those marks on the application is not.
