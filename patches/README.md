# Patches

Modifications to the engine that Lukotta carries. `scripts/build-engine.sh`
fetches every source pinned in `vendor/engine.lock`, verifies it against the
checksums the release verifies, applies every patch in this directory, and
builds the two binaries that change. All other components come from the
checksummed bottle.

Each patch is applied to the source it is named after: `imago-*` to the imago
crate, `krun-devices-*` to the krun-devices crate, and the remainder to
anylinuxfs. Those two crates form the engine's image layer and are compiled into
the host binary rather than loaded beside it, so the build directs Cargo to the
patched copies with `[patch.crates-io]`.

`scripts/vendor-engine.sh` records the names of the applied patches in
`engine/anylinuxfs/PATCHES`. The application determines from that file which
formats the engine supports. A build made without this step is fully functional
without these modifications, and reports the formats it cannot open by name.

## Licensing

anylinuxfs is licensed under GPL-3.0-or-later, imago under MIT, and krun-devices
under Apache-2.0. All three are compatible with the GPL-3.0-or-later terms under
which Lukotta as a whole is conveyed.

A change to an existing file is made under the licence that file already
carries. The three files added to imago, `src/vdi/mod.rs`, `src/vhd/mod.rs` and
`src/vhdx/mod.rs`, are licensed under that crate's MIT terms and carry
`SPDX-FileCopyrightText` and `SPDX-License-Identifier` tags recording it. Those
terms are chosen so that the drivers may be offered upstream; the
GPL-3.0-or-later terms covering Lukotta do not extend to them.

Every file a patch modifies carries a notice of the modification and its date,
as section 5(a) of the GNU General Public License version 3 and section 4(b) of
the Apache License 2.0 require. `collect-sources.sh` places all three upstream
sources and every patch in this directory into the corresponding source
accompanying each release, so that a recipient receives the modifications
together with the works they modify.

## vmproxy-decrypt-what-it-probes.patch

**Defect.** An encrypted volume inside a disk image was never unlocked. The host
probes an image only far enough to establish that it is one, so `unprobed_image`
sets `fs_type: "auto"` and the list of devices to decrypt, which is derived from
that type, is empty. Within the guest, `blkid` then reports `crypto_LUKS`
correctly, and that string is passed to `mount` as a filesystem type:

    mount args: ["-t", "crypto_LUKS", "/dev/vda", "/mnt/container.qcow2"]
    mount: unknown filesystem type 'crypto_LUKS'

**Change.** The guest already contains the necessary logic in
`activate_volume_managers`, which runs when the host has supplied the type.
After `detect_fs_type` establishes the true type, an encrypted volume that has
not already been decrypted is unlocked and probed again.
`prepare_for_probed_encryption` selects the tool beforehand, because the choice
between `cryptsetup open` and `bitlkOpen` is otherwise made from the type
supplied by the host, which for an image is `auto`.

**Verification.** A LUKS2 container within a qcow2 image mounts, and a file
written into it reads back unchanged. The end-to-end test covers this case.

## anylinuxfs-image-formats.patch

**Purpose.** Exposes the VMDK, VDI, VHD and VHDX formats. libkrun accepts a
format number in `krun_add_disk2` and the engine's image layer contains the
corresponding drivers, but the `DiskFormat` enumeration in anylinuxfs ended at
`Raw` and `Qcow2`, so no other format could be requested.

**Change.** Adds the four cases, maps each to its format number, recognises the
corresponding file extensions, and replaces three `== DiskFormat::Qcow2` tests
with `is_encoded()`, each of those tests having asked whether the image required
decoding at all. `.vhdx` is tested before `.vhd`, which is a suffix of it and a
separate format.

**Verification.** Images in each format are read, mounted and ejected through
the application, including a VMDK holding a LUKS container. The end-to-end test
constructs one of each and opens it.

## imago-vdi-vhd-and-vhdx.patch

**Purpose.** Adds three drivers to imago, the crate that reads image formats for
the engine, and registers them in `Format`. VDI and VHD are read and written;
VHDX is read only, for the reason given below.

**VDI.** VirtualBox's format: a header, a map holding one 32-bit entry for each
block of the virtual disk, and the blocks in the order they were written. Two
map values denote a block that was never written and reads as zeroes, which
keeps a largely empty disk small.

**VHD.** Microsoft's first format, in both forms that hold their own data. A
fixed VHD is the raw disk followed by a 512-byte footer. A dynamic VHD stores
the disk in blocks listed by an allocation table, each preceded by a bitmap
sector. A differencing VHD holds only the changes from a parent disk that it
names, and is refused: no driver here opens a second file.

**VHDX.** Microsoft's second format. Several structures must be located before
the disk can be read: a file signature, two headers of which the live one
carries the higher sequence number and a sound CRC-32C, a region table locating
the remainder, a metadata region giving the block size and the disk size, and an
allocation table whose payload entries are interleaved with entries describing
sector bitmaps.

Two images are refused. One that names a parent holds only the changes from
another disk. One whose log is not empty was not closed cleanly: its most recent
state is in that log, replaying the log requires writing, and disregarding it
returns data older than the disk last held.

**Why VHDX is not written.** The format requires every change to the allocation
table or the metadata to be written into the log first, so that a writer
interrupted part-way leaves a file the next reader can repair, and requires a
new write identifier in one of the two headers, each carrying a sequence number
and a CRC-32C. A writer that skips the log leaves no trace that anything was
interrupted, which is the one failure nobody can detect afterwards. The log is
therefore a precondition for writing a VHDX at all, and it is not written here.
The driver reports itself as not writable, and the device the guest is given is
marked read-only, so a VHDX fails to mount writable rather than failing during
one.

**Writing VDI and VHD.** A fixed VHD and a static VDI hold every byte of the
disk already, so a write goes where the data is. The growing forms allocate:
a dynamic VHD puts a new block over the trailing footer and moves the footer to
the new end of the file; a VDI puts a new block after the last one. In both the
space is made before anything points at it, and the table that points at it is
written last, so an interrupted write leaves the image it was with unused space
at the end. A VDI's count of allocated blocks is written before its map entry,
so a block is never handed out twice.

Each driver validates every value it reads before relying on it: block sizes are
required to be powers of two, maps are bounded to a size any real disk could
require, and every entry must lie within the file. A damaged or hostile image
therefore cannot direct a driver to read an unrelated part of the file and
present it as the disk.

**Verification.** `src/write_tests.rs`, added by this patch, creates images with
`qemu-img`, writes to them through the drivers, and then has `qemu-img` check
each image and convert it to raw, comparing every byte against a model kept
beside the writes. The cases are the first block, a write crossing two, one
aligned to nothing, a second write over ground already allocated, several blocks
at once, the last byte of the disk, filling an image completely, and two hundred
randomly placed writes per format from a fixed seed. Each image is reopened from
scratch before it is checked, so metadata that never reached the file cannot be
covered by what is still in memory.

qcow2 is covered as well, though its driver is imago's own rather than one added
here, since the application leans on it. The case worth stating is a qcow2
holding an internal snapshot: clusters shared with a snapshot have to be copied
before they are written rather than written through. The test snapshots an
image, writes to it, has qemu-img check and convert it, then applies the
snapshot back and checks the image again.

Reference images written by `qemu-img` in each of the three
formats read back byte for byte identical to the raw disk from which they were
made, and all three mount and eject through the application. `qemu-img compare`
reads the images produced by `scripts/make-vdi.py`, `scripts/make-vhd.py` and
`scripts/make-vhdx.py` and finds each identical to the same raw disk, so the
readers and the writers were each checked against a separate implementation.
Three further VHDX images were constructed by hand: one with a log that is not
empty and one naming a parent are refused by name, and one whose first header is
damaged is read correctly through the second.

## imago-sparse-vmdk.patch

**Purpose.** imago's VMDK driver read the flat form, a text descriptor beside a
raw extent, and refused the sparse form with *"Unsupported VMDK sparse data
file"*. The sparse form is what a virtual machine writes while running; the flat
form is what an export produces.

**Change.** Reads the sparse form. Such a file holds the header, the descriptor
that a flat VMDK keeps in a separate file, a grain directory, the grain tables
and the grains, one for each 64 KB of disk written to. The descriptor is read
from within the file at the offset the header gives, `SPARSE` extents are
recognised, and an offset into the disk is resolved through the directory and a
table onto a grain. A grain that was never written, or was written as zeroes,
reads as zeroes.

The grain directory is read once, when the image is opened. The grain tables are
read as the disk is read, and the most recent sixty-four are retained, since one
table covers a long stretch of disk and reading an image through refers to each
approximately once. A VMDK's tables are proportional to the capacity of the disk
rather than to the data written to it, so reading them in full would make a
large sparse image expensive to open.

**Stream-optimized VMDK.** Read as well. Every grain in this form is deflated
and preceded by a marker identifying the part of the disk it holds, so no region
of the file corresponds to a region of the disk and no mapping can refer to one.
Those reads are served through `readv_special()`, each grain being inflated in
full and retained in a cache of the most recent thirty-two. imago already
depends on `miniz_oxide` for qcow2's compressed clusters, so this required no
further dependency, only the zlib-header flag, VMDK wrapping the deflate stream
where qcow2 does not.

A file in this form is written in a single pass, so the position of its grain
directory is fixed only once everything preceding it has been written. The
header then carries a placeholder and a copy of the header at the end of the
file carries the true offset. Both arrangements are read: `qemu-img` records the
offset in the header, and VMware records the placeholder.

**Writing.** A sparse extent grows by putting a new grain after the end of the
extent and recording it in the grain table, and in the redundant grain table
beside it where the extent has one, that copy being what VMware repairs an
extent from. A stretch of disk no table covers gets a table first, in both
directories. The stream-optimized form is not written: every grain in it is
deflated, so changing one in place would rarely produce the same number of
bytes. Opening one for writing fails by name, and the device the guest is given
is marked read-only.

**Verification.** A sparse VMDK written by `qemu-img` reads back byte for byte
identical to the raw disk from which it was made and mounts through the
application. The write tests described above cover `monolithicSparse`,
`monolithicFlat`, `twoGbMaxExtentSparse` and `twoGbMaxExtentFlat`, and a sparse
image whose grain directory was emptied by hand, so that the driver has to make
a grain table rather than fill one in. The image produced by `scripts/make-vmdk-sparse.py` is read by
`qemu-img compare`, which finds it identical to the same disk, and by `qemu-img
check`, which reports no errors. The same holds for the stream-optimized form,
including an image constructed by hand to use the placeholder arrangement, which
`qemu-img` does not write. The flat form reads as before.

## krun-devices-image-formats.patch

**Purpose.** Adds `ImageType::Vdi`, `ImageType::Vhd` and `ImageType::Vhdx`, maps
disk formats 3, 4 and 5 to them, and opens each with the corresponding imago
driver. libkrun itself requires no change, as `krun_add_disk2` passes the format
number directly to this enumeration.

**Writability.** Each driver is opened for writing when the disk was not
requested read-only, except VHDX, which is never writable. The device is then
marked read-only to the guest whenever the driver reports it cannot be written,
which covers a VHDX, a stream-optimized VMDK and an extent a descriptor marks
read-only. Without that the guest is told a device is writable while every write
is refused, and the failure arrives inside a filesystem driver part-way through
whatever it was doing rather than at `mount`. A stream-optimized VMDK asked for
read-write is opened a second time read-only rather than failing to open.

**Three arms, on purpose.** The VMDK, VDI and VHD arms each spell out the same
open-then-reopen-read-only shape. A generic helper would halve the largest hunk
here, and is not worth it: this is a diff against somebody else's crate, and
three explicit arms with a comment each — why VHDX gets no fallback, why the
VMDK one is reached today and the other two are there for a driver that starts
refusing — read more plainly to an upstream reviewer than a closure taking an
opener. Worth revisiting if a fourth format lands.

## Build requirements

Building the engine requires a Rust toolchain and, because vmproxy is a Linux
binary and libkrun embeds a Linux init, Homebrew's llvm, lld and util-linux:

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

## Images that reference other files

libkrun's own header records that formats other than raw may reference other
files, which libkrun opens. A qcow2 backing file and a VMDK descriptor naming
its extents are both such references, so an image can determine which other
files the virtual machine reads.

Lukotta refuses any qcow2 that names another file before the engine is given the
path; see `Qcow2Header.namesAnotherFile`. A VDI cannot name one, its data always
being its own. A VHD can do so only in the differencing form, and a VHDX only by
naming a parent; the drivers refuse both, and the application refuses them again
by name before the engine is given the path.

A VMDK requires a rule of its own, since it always names another file. The
descriptor is read in full and capped at 2 MB, so no self-contained form exists.
Every extent must therefore be a plain file name situated beside the descriptor:
nothing absolute, nothing containing a separator, and no `..`. That is what
VMware writes, and it prevents a descriptor from reaching elsewhere on the disk.
See `VmdkDescriptor.namesAFileElsewhere`.

Container files are also opened without privilege, which limits the reach of any
such reference to what the person who opened the file could already read. These
checks are not relaxed as further formats are added.
