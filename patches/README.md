# Patches

Changes to the engine that Lukotta carries. `scripts/build-engine.sh` fetches
every source pinned in `vendor/engine.lock` — the same checksums the release
verifies — applies everything here, and builds the two binaries that change.
Everything else still comes from the checksummed bottle.

Each patch is applied to whichever source it is named after: `imago-*` to the
imago crate, `krun-devices-*` to that crate, and everything else to anylinuxfs
itself. The two crates are the engine's image layer — they are built into the
host binary rather than loaded beside it — and the build points at the patched
copies with `[patch.crates-io]`.

`scripts/vendor-engine.sh` writes the names of the applied patches into
`engine/anylinuxfs/PATCHES`, and the app reads that rather than assuming what it
can do. **Building without this step produces a working app** — one without
these fixes, which then says so instead of failing oddly.

anylinuxfs is GPL-3.0-or-later, like Lukotta; imago is MIT and krun-devices is
Apache-2.0, both of which the GPL absorbs. `collect-sources.sh` puts all three
sources and all of these patches into the corresponding source shipped with
every release, so a recipient gets the modifications as well as the originals.

## vmproxy-decrypt-what-it-probes.patch

**The bug.** Encryption inside a disk image was never unlocked. The host probes
an image only far enough to know that it is one — `unprobed_image` sets
`fs_type: "auto"` — so the list of devices to decrypt, which is built from that
type, comes out empty. Inside the guest, `blkid` then correctly reports
`crypto_LUKS`, and that string is passed to `mount` as a filesystem type:

    mount args: ["-t", "crypto_LUKS", "/dev/vda", "/mnt/container.qcow2"]
    mount: unknown filesystem type 'crypto_LUKS'

**The fix.** The guest already knows how to unlock — `activate_volume_managers`
does exactly this when the host said the type. So after `detect_fs_type` has
found the truth, if it is an encrypted volume and nothing was decrypted already,
unlock it and look again. `prepare_for_probed_encryption` picks the right tool
first, because the choice between `cryptsetup open` and `bitlkOpen` is otherwise
made from the type the host sent, which for an image is "auto".

**Verified.** A LUKS2 container inside a qcow2 mounts, and the file written into
it reads back. The end-to-end test covers it.

## anylinuxfs-image-formats.patch

**What it does.** Exposes VMDK, VDI and VHD. libkrun already reads the format —
`KRUN_DISK_FORMAT_VMDK = 2` sits in its header beside `RAW` and `QCOW2`, and the
image layer inside the engine carries VMDK descriptor parsing — but anylinuxfs's
own `DiskFormat` enum stopped at `Raw` and `Qcow2`, so nothing could ask for it.
The patch adds the case, maps the constant, recognises `.vmdk`, and replaces
three `== DiskFormat::Qcow2` tests with `is_encoded()`, since each was really
asking whether the image needed decoding at all. `.vdi` and `.vhd` were added
the same way once the drivers below existed, as formats 3 and 4.

**Tested.** A monolithicFlat VMDK — a text descriptor beside a raw extent, which
is what VMware writes — is read, mounted and ejected through the app, including
one holding a LUKS container. The end-to-end test builds one and opens it.

Sparse VMDKs and snapshot chains are not supported by the engine's image layer,
and the app says so by name rather than letting either fail obscurely.

## imago-vdi-vhd-and-vhdx.patch

**What it does.** Adds two read-only drivers to imago, the crate that reads
image formats for the engine, and lists them in `Format` so the rest of the
crate can name them.

`vdi` reads VirtualBox's format: a header, a map with one 32-bit entry per block
of the virtual disk, and the blocks in whatever order they were written. Two map
values mean the block was never written and reads as zeroes, which is how a
mostly-empty disk stays small.

`vhd` reads Microsoft's, in both shapes that hold their own data — **fixed**,
which is the raw disk with a 512-byte footer after it, and **dynamic**, which
stores blocks listed by an allocation table with a bitmap sector before each.
A **differencing** VHD holds only what changed from a parent disk it names, and
is refused: neither driver ever opens a second file. VHDX shares the name and
nothing else, and is not this format.

Both check what they read before they use it — block size a power of two, the
map no larger than any real disk could need, every entry inside the file — so a
damaged or hostile image cannot make the driver read some other part of the file
and serve it as the disk.

**Tested.** Reference images written by `qemu-img` — a VDI, a dynamic VHD and a
fixed VHD — read back byte for byte identical to the raw disk they were made
from, and all three mount and eject through the app. In the other direction,
`qemu-img compare` reads the images `scripts/make-vdi.py` and
`scripts/make-vhd.py` write and finds them identical to the same raw disk. So
the readers and the writers were each checked against something that was not the
other.

## imago-sparse-vmdk.patch

**The gap.** imago's VMDK driver reads the flat form — a text descriptor beside
a raw extent — and refuses the sparse one outright: *"Unsupported VMDK sparse
data file"*. But sparse is what a VM writes while it is running, and what most
people have; flat is what an export produces.

**What it does.** Reads the sparse form as well. A sparse VMDK is one file
holding the header, the descriptor a flat VMDK keeps in a file of its own, a
grain directory, the grain tables, and then the grains — one per 64 KB of disk
that was written to. So the descriptor is read from inside the file at the
offset the header gives, `SPARSE` extents are recognised, and a guest offset is
mapped through the directory and a table onto a grain. A grain never written, or
written as zeroes, reads as zeroes.

The grain directory is read once, when the image is opened; the tables are read
as the disk is, and the last sixty-four are kept, because one table covers a
long stretch of disk and reading an image through touches each about once. That
keeps a large sparse disk from being a large allocation.

The **stream-optimized** form, whose grains are compressed and preceded by
markers, is refused by name — the app refuses it too, before the engine is told
anything.

**Tested.** A sparse VMDK written by `qemu-img` reads back byte for byte
identical to the raw disk it was made from, and mounts through the app; the one
`scripts/make-vmdk-sparse.py` writes is read by `qemu-img compare`, which finds
it identical to the same disk, and by `qemu-img check`, which finds no errors.
The flat form still reads as it did.

### VHDX, in the same patch

The last of them, and the only one with more than one thing to find: a file
signature, two headers of which the live one is whichever has the higher
sequence number **and** a sound CRC-32C, a region table saying where the rest
is, a metadata region giving the block size and the disk size, and an allocation
table whose payload entries are interleaved with ones describing sector bitmaps.

Two images are refused rather than read:

- one that **names a parent** holds only what changed from another disk, and
  nothing here opens a second file;
- one whose **log is not empty** was not closed cleanly. Its newest state is in
  that log. Replaying it means writing, which a read-only driver must not do,
  and ignoring it means quietly serving something older than what the disk last
  held — the failure that gets mistaken for corruption.

**Tested.** qemu-img's VHDX reads back byte for byte identical to the raw disk
it was made from and mounts through the app, and `qemu-img compare` says the
same of the one `scripts/make-vhdx.py` writes. Three awkward variants were made
by hand: a dirty log and a parent link are each refused by name, and an image
whose first header is damaged is read through the second.

## krun-devices-image-formats.patch

**What it does.** Adds `ImageType::Vdi` and `ImageType::Vhd`, maps disk formats
3 and 4 onto them, and opens each with the matching imago driver. libkrun itself
needs no change: `krun_add_disk2` passes the number straight through to this
enum.

## What this costs

Building the engine needs a Rust toolchain and, because vmproxy is a Linux
binary and libkrun embeds a Linux init, Homebrew's llvm, lld and util-linux:

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

## A note that outlives these patches

From libkrun's own header: formats other than raw **can reference other files,
which libkrun opens**. A qcow2 backing file, a VMDK descriptor naming its
extents. So an image can choose which other files the virtual machine reads.

Lukotta refuses any qcow2 that names another file, before the engine is told
anything about it — see `Qcow2Header.namesAnotherFile`. A VDI cannot name one:
its data is always its own. A VHD can, but only the differencing kind, which the
driver refuses and the app refuses again by name before the engine sees it.

A VMDK is different and needs its own rule: it **always** names another file.
The descriptor is read whole and capped at 2 MB, so the data cannot live inside
it — there is no self-contained form. So the rule there is that every extent
must be a plain file name sitting beside the descriptor: nothing absolute,
nothing with a separator, no `..`. That is exactly what VMware writes, and it
stops a descriptor reaching anywhere else on the disk. See
`VmdkDescriptor.namesAFileElsewhere`.

Container files also run unprivileged, which bounds the reach to what the person
who opened it could already read. None of that is a reason to relax the checks
when more formats are added.
