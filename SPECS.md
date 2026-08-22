# Specifications

What Lukotta opens, how, and what it does not open and why.

Lukotta hands a drive or a file to a Linux virtual machine, mounts it there, and
re-exports it over NFS so that Finder sees an ordinary volume. Everything below
follows from that arrangement: what Linux can mount, Lukotta can open, provided
the bytes reach Linux in a form it recognises.

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
mounted however the bytes arrive.

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

| Format | Opened | How |
| --- | --- | --- |
| Raw (`.img`, `.dmg`, and any unrecognised extension) | Yes | Attached by macOS, then mounted in the guest |
| qcow2 | Yes | Read by the engine's image layer; nothing is attached |
| VMDK, flat (`monolithicFlat`) | Yes | A text descriptor beside a raw extent |
| VMDK, sparse (`monolithicSparse`) | Yes | Grain directory, grain tables, grains |
| VMDK, stream-optimized | Yes | Deflated grains, each behind a marker. This is what an OVA carries |
| VDI | Yes | VirtualBox's format |
| VHD, fixed | Yes | The raw disk with a 512-byte footer after it |
| VHD, dynamic | Yes | Blocks listed by an allocation table |
| VHDX | Yes | Header pair, region table, metadata region, allocation table |
| VMDK snapshot chains | No | Names a parent file. See §3 |
| VHD, differencing | No | Names a parent file. See §3 |
| VHDX with a parent | No | Names a parent file. See §3 |
| VHDX with a log that is not empty | No | See §6 |
| Sparse bundles, encrypted DMG | No | macOS opens both natively. See §5 |

The VMDK, VDI, VHD and VHDX drivers are Lukotta's own, written for imago, the
crate that reads image formats for the engine. See `patches/README.md`.

---

## 2. How it works

Four layers carry a disk image from a file name to a mounted volume, and all
four are Lukotta's to change:

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
NFS. This requires the privileged helper, because reading a raw disk device does.

**A disk image** is opened without privilege. A raw image is attached by macOS
first; every other format is handed to the engine as a path, and the engine
reads the format itself. Nothing is attached, and the mount appears under
`~/Volumes` rather than `/Volumes`, so no part of the operation is elevated.

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
reference to what the person who opened the file could already read. None of
that is grounds for relaxing the checks as further formats are added.

---

## 4. What is handed to macOS instead

An exFAT image is attached by macOS and left mounted there, rather than being
carried through the virtual machine. macOS reads and writes exFAT natively, so
routing it through NFS would add a layer that serves no purpose and would take
the volume out of Finder's hands. The application says so on screen when it
happens, so that the volume's appearance in `/Volumes` rather than `~/Volumes`
is not a surprise.

The same reasoning applies to the drive list: a disk macOS already reads is
listed with that as its verdict rather than offered for opening.

---

## 5. What is not supported, and why

### FileVault 2

macOS opens it natively, and the guest has no HFS+ or APFS driver, so a volume
unlocked there could not then be mounted. cryptsetup's `fvault2` handler exists
but leads nowhere without a filesystem driver behind it. There is no version of
this that is better than what macOS already does.

### Encrypted DMG and sparse bundles

macOS opens both natively and integrates them with Keychain and Finder. Nothing
Lukotta could add would improve on that.

### VeraCrypt and TrueCrypt

cryptsetup carries an independent `tcrypt` implementation, and it is in the
guest already. It is not reachable from the application, since the engine
decides what to unlock from what `blkid` reports, and a TrueCrypt volume has no
signature to report: the header is indistinguishable from random data by design.
Opening one requires the user to state that a device is a TrueCrypt volume and
supply the passphrase. That is a plausible future addition; it needs an
interface, not a new dependency.

### Stream-optimized VMDK inside an OVA

The format itself is read. An OVA is a tar archive containing a descriptor and
one of these images, and Lukotta does not extract archives. Extract the `.vmdk`
and open that.

### VHDX with a log that is not empty

An image that was not shut down cleanly keeps its most recent state in its log.
Replaying that log is a write, and Lukotta does not write to a disk image.
Reading the file without replaying it returns data older than the disk last
held, which is the failure most easily mistaken for corruption. The image is
therefore refused by name, with the remedy stated: open it once in the virtual
machine it belongs to, which empties the log.

This could be done without writing to the file. imago's `readv_special()` allows
a driver to serve bytes itself, so a log could be replayed into memory and
applied to the structures the driver has already read. The obstacle is
verification: a genuinely dirty image is difficult to obtain, and an image
written by the same author as the reader tests only that they agree with each
other.

### qemu in the guest

Investigated and rejected. The guest kernel has no `nbd` module, the FUSE export
path is absent, and `nbdfuse` is not packaged for Alpine. This was tested rather
than assumed, and it is the reason the format drivers live in imago instead.

---

## 6. Where the drivers came from

imago read raw, qcow2 and flat VMDK. Everything else in the table above was
added as read-only drivers in `patches/imago-*.patch`:

| Driver | Shape | Size |
| --- | --- | --- |
| VDI | Header, then a flat block map of 32-bit indices | ~380 lines |
| VHD | Trailing footer; blocks listed by an allocation table | ~400 lines |
| VHDX | Header pair, region table, metadata region, allocation table | ~430 lines |
| VMDK, sparse and streamed | Grain directory, grain tables, deflated grains | ~470 lines |

Every driver is read-only and validates each value before relying on it: block
sizes must be powers of two, maps are bounded to a size a real disk could
require, and every entry must lie within the file. A damaged or hostile image
cannot direct a driver to read an unrelated part of the file and present it as
the disk.

Each was verified in both directions, since a reader and a writer written by the
same author agree with each other and with nothing else. Images written by
`qemu-img` read back byte for byte identical to the raw disk they were made
from, and `qemu-img compare` reads the images the scripts under `scripts/`
produce and finds them identical to the same disk. Every format then mounts and
ejects through the application in the end-to-end run, which uses the images
those scripts write, so the test suite requires neither qemu nor VirtualBox.

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
