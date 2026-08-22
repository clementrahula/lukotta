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
| VHDX | Yes | **No** | Header pair, region table, metadata region, allocation table. See §6 |
| VMDK snapshot chains | No | | Names a parent file. See §3 |
| VHD, differencing | No | | Names a parent file. See §3 |
| VHDX with a parent | No | | Names a parent file. See §3 |
| VHDX with a log that is not empty | No | | See §6 |
| Sparse bundles, encrypted DMG | No | | macOS opens both natively. See §5 |

The VMDK, VDI, VHD and VHDX drivers were written here for imago, the crate that
reads image formats for the engine. See `patches/README.md`.

An image that cannot be written is opened read-only, and the guest is told the
device is read-only, so the mount fails at once rather than part-way through a
write. The application then mounts it read-only instead, which is what the
`read-only` stage marker in §2 reports.

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
| VMDK | Every extent must be a plain file name situated beside the descriptor: nothing absolute, nothing containing a separator, no `..`. That is what VMware writes. A `parentFileNameHint` is refused |
| VHD | A differencing image is refused |
| VHDX | An image naming a parent is refused |
| VDI | Cannot name another file; its data is always its own |

The drivers refuse these images as well, so the rule holds in both layers. Disk
images are also opened without privilege, which limits the reach of any such
reference to what the person who opened the file could already read. The checks
are not relaxed as further formats are added.

---

## 4. What is handed to macOS instead

An exFAT image is attached by macOS and left mounted there rather than carried
through the virtual machine. macOS reads and writes exFAT natively, so routing
it through NFS would add a layer that serves no purpose and would remove the
volume from Finder's control. The application states this on screen, since the
volume then appears in `/Volumes` rather than `~/Volumes`.

The same reasoning applies to the drive list: a disk macOS already reads is
listed with that as its verdict rather than offered for opening.

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

VHDX is read and never written. The format requires that every change to its
allocation table or its metadata be written into its log first, so that a writer
interrupted part-way leaves a file the next reader can repair; a writer must
also stamp a new write identifier into one of the two headers, each carrying a
sequence number and a CRC-32C. A writer that skips the log leaves no trace that
anything was interrupted, which is the one failure that cannot be detected
afterwards. Writing the log is therefore a precondition for writing a VHDX at
all, and it is not written here.

The consequence is deliberate and visible: a VHDX opens read-only, the guest is
told the device is read-only, and the application says so before anything is
mounted rather than after a write has failed.

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

Borrowing QEMU's block layer, which has written all of these formats for many
years, was measured rather than assumed:

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

### How it is checked

`qemu-img` is the oracle. QEMU has written these formats for many years, so
agreeing with it is the strongest statement these drivers can make. The tests in
`src/write_tests.rs`, carried by the imago patch, create an image with
`qemu-img`, write to it through the driver, and then have `qemu-img` check the
image and convert it to raw, comparing every byte against a model kept beside
the writes. They cover the first block, a write crossing two, one aligned to
nothing, a second write over ground already allocated, several blocks at once,
the last byte of the disk, filling an image completely, a grain directory with a
gap in it, and two hundred randomly placed writes per format from a fixed seed.

Reading was verified the same way and in both directions: images written by
`qemu-img` read back byte for byte identical to the raw disk they were made
from, and `qemu-img compare` reads the images the scripts under `scripts/`
produce and finds them identical. Every format then mounts and ejects through
the application in the end-to-end run, which uses the images those scripts
write, so the application's own test suite requires neither qemu nor
VirtualBox.

---

## 7. Licensing

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
