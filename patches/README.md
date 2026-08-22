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
with `is_encoded()`, each of which was in fact establishing whether the image
required decoding at all. `.vhdx` is tested before `.vhd`, of which it is a
suffix and a distinct format.

**Verification.** Images in each format are read, mounted and ejected through
the application, including a VMDK holding a LUKS container. The end-to-end test
constructs one of each and opens it.

## imago-vdi-vhd-and-vhdx.patch

**Purpose.** Adds three read-only drivers to imago, the crate that reads image
formats for the engine, and registers them in `Format`.

**VDI.** VirtualBox's format: a header, a map holding one 32-bit entry for each
block of the virtual disk, and the blocks in the order they were written. Two
map values denote a block that was never written and reads as zeroes, which is
how a largely empty disk remains small.

**VHD.** Microsoft's first format, in both forms that hold their own data. A
fixed VHD is the raw disk followed by a 512-byte footer. A dynamic VHD stores
the disk in blocks listed by an allocation table, each preceded by a bitmap
sector. A differencing VHD holds only the changes from a parent disk that it
names, and is refused: no driver here opens a second file.

**VHDX.** Microsoft's second format, which requires several structures to be
located before the disk can be read: a file signature, two headers of which the
live one is whichever carries the higher sequence number together with a sound
CRC-32C, a region table locating the remainder, a metadata region giving the
block size and the disk size, and an allocation table whose payload entries are
interleaved with entries describing sector bitmaps. Two images are refused. One
that names a parent holds only the changes from another disk. One whose log is
not empty was not closed cleanly; its most recent state resides in that log,
replaying the log would require writing, and disregarding it would return data
older than the disk last held.

Each driver validates every value it reads before relying on it: block sizes are
required to be powers of two, maps are bounded to a size any real disk could
require, and every entry must lie within the file. A damaged or hostile image
therefore cannot direct a driver to read an unrelated part of the file and
present it as the disk.

**Verification.** Reference images written by `qemu-img` in each of the three
formats read back byte for byte identical to the raw disk from which they were
made, and all three mount and eject through the application. In the opposite
direction, `qemu-img compare` reads the images produced by
`scripts/make-vdi.py`, `scripts/make-vhd.py` and `scripts/make-vhdx.py` and
finds each identical to the same raw disk. Readers and writers were therefore
each verified against an implementation that was not the other. Three further
VHDX images were constructed by hand: one with a log that is not empty and one
naming a parent are refused by name, and one whose first header is damaged is
read correctly through the second.

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

**Stream-optimized VMDK.** Also read. Every grain in this form is deflated and
preceded by a marker identifying the part of the disk it holds, so no region of
the file corresponds to a region of the disk and no mapping can refer to one.
Those reads are served through `readv_special()`, each grain being inflated in
full and retained in a cache of the most recent thirty-two. imago already
depends on `miniz_oxide` for qcow2's compressed clusters, so no further
dependency is required, only the zlib-header flag, since VMDK wraps the deflate
stream where qcow2 does not.

A file in this form is written in a single pass, so the position of its grain
directory is fixed only once everything preceding it has been written. The
header then carries a placeholder and a copy of the header at the end of the
file carries the true offset. Both arrangements are read: `qemu-img` records the
offset in the header, and VMware records the placeholder.

**Verification.** A sparse VMDK written by `qemu-img` reads back byte for byte
identical to the raw disk from which it was made and mounts through the
application. The image produced by `scripts/make-vmdk-sparse.py` is read by
`qemu-img compare`, which finds it identical to the same disk, and by `qemu-img
check`, which reports no errors. The same holds for the stream-optimized form,
including an image constructed by hand to use the placeholder arrangement, which
`qemu-img` does not write. The flat form reads as before.

## krun-devices-image-formats.patch

**Purpose.** Adds `ImageType::Vdi`, `ImageType::Vhd` and `ImageType::Vhdx`, maps
disk formats 3, 4 and 5 to them, and opens each with the corresponding imago
driver. libkrun itself requires no change, as `krun_add_disk2` passes the format
number directly to this enumeration.

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
such reference to what the person who opened the file could already read. None
of this is grounds for relaxing these checks as further formats are added.
