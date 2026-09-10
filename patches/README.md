# Patches

<!-- covers: patches/** -->

Modifications to the engine that Lukotta carries. `scripts/build-engine.sh`
fetches every source pinned in `vendor/engine.lock`, verifies it against the
checksums the release verifies, applies every patch in this directory but the
guest kernel's, and builds the two binaries that change. All other components
come from the checksummed bottle.

Each patch is applied to the source it is named after: `imago-*` to the imago
crate, `krun-devices-*` to the krun-devices crate, `linux-*` to the guest
kernel by `scripts/build-guest-kernel.sh`, and the remainder to anylinuxfs. The
two crates form the engine's image layer and are compiled into the host binary
rather than loaded beside it, so the build directs Cargo to the patched copies
with `[patch.crates-io]`.

`scripts/vendor-engine.sh` records the names of the applied patches in
`engine/anylinuxfs/PATCHES`. The application determines from that file which
formats the engine supports. A build made without this step is fully functional
without these modifications, and reports the formats it cannot open by name.

## Licensing

anylinuxfs is licensed under GPL-3.0-or-later, imago under MIT, and krun-devices
under Apache-2.0. All three are compatible with the GPL-3.0-or-later terms under
which Lukotta as a whole is conveyed. The guest kernel is licensed under
GPL-2.0-only; it runs inside the virtual machine as a program of its own and is
not combined with Lukotta, and a change to one of its files is made under that
file's GPL-2.0 terms.

A change to an existing file is made under the licence that file already
carries. The three files added to imago, `src/vdi/mod.rs`, `src/vhd/mod.rs` and
`src/vhdx/mod.rs`, are licensed under that crate's MIT terms and carry
`SPDX-FileCopyrightText` and `SPDX-License-Identifier` tags recording it. Those
terms are chosen so that the drivers may be offered upstream; the
GPL-3.0-or-later terms covering Lukotta do not extend to them.

Every file a patch modifies carries a notice of the modification and its date,
as section 5(a) of the GNU General Public License version 3, section 2(a) of
version 2 and section 4(b) of the Apache License 2.0 require.
`collect-sources.sh` places all three upstream sources and every patch in this
directory into the corresponding source accompanying each release, so that a
recipient receives the modifications together with the works they modify.

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

## anylinuxfs-private-home.patch

**Purpose.** Gives the engine a state directory the caller names, so that two
applications carrying it do not share one.

anylinuxfs keeps its Linux image and configuration in `~/.anylinuxfs` and its
logs in `~/Library/Logs`. That is right for a program somebody installed
themselves. It is wrong for an application that carries the engine inside it,
because several can be installed at once — a release, a pre-release, and
anylinuxfs itself — and each ships the image version its own engine was built
against. One directory between them means each finds an image it did not put
there.

**Change.** `ANYLINUXFS_HOME` moves the image, the configuration and the logs.
The home directory itself is still resolved from the invoking user, because it
decides something else: where an unprivileged mount appears. Drives belong in
`~/Volumes`, not wherever an application keeps its files.

**Verification.** The end-to-end run records the other channel's directory
before it starts and compares it afterwards; a run that wrote into it fails.
Both channels are run in both orders.

## anylinuxfs-serve-volumes-unprivileged.patch

**Defect.** A volume group opened from a disk image gave a read-only folder
holding one empty directory per volume. The engine mounts the group's own
directory first and then each volume inside it, and those later mounts were
escalated with `sudo` — always, and not because anything needed it. `elevate` is
decided by how the process was started, never by whether the mount would have
worked without it:

    macOS: need to use sudo to mount additional NFS exports
    macOS: Failed to mount additional NFS exports: mount failed with exit code 1

Where somebody was there to type a password, they were asked for one in the
middle of opening a file. Where nobody was, the volumes were simply not there.

**Change.** On macOS the sub-mounts are made the way the mount above them was
made: as whoever is running the engine. macOS permits a mount on a directory its
owner holds, which is what the parent mount already demonstrated. Linux keeps
the previous behaviour, mounting there requiring privilege.

**Verification.** Tested by hand first: `mount -t nfs` on a subdirectory of a
share already mounted returns 0 as an ordinary user. Then through the
application, where a LUKS2 container holding a volume group of three volumes
mounts all three, each takes a file, and each file is still there when the image
is opened again by a new machine. The end-to-end run covers it where
`scripts/make-test-volumes.sh` has been run.

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

## anylinuxfs-vmnet-reachable.patch

**Defect.** With `--net-helper vmnet`, nothing on the host could reach the
guest. The mount ended at

    macOS: Checking NFS server on 172.27.1.2:2049...
    macOS: Error connecting to port 2049: No route to host (os error 65)

while inside the guest everything looked right: `eth0` up, addressed
`172.27.1.2/30`, a default route through `172.27.1.1`, the drive mounted, and
`nfsd` listening. The guest could ping the host in 0.4 ms. The host had a route
and a resolved ARP entry for the guest, and could reach nothing.

vmnet assigns a MAC address when the interface is created, reports it in the
JSON the helper prints, and afterwards delivers unicast only to that address.
The guest NIC was given `random_mac_address()` instead, so it wore an address
vmnet had never heard of. Broadcast still arrives, which is why ARP was answered
and the host learned a neighbour it could never talk to; every unicast frame was
dropped by vmnet before it reached the guest. The guest's own counters showed
frames coming in, all of them broadcast, and `/proc/net/snmp` recorded
`Icmp: InEchos 0` while the host was pinging it.

**Second defect, behind the first.** vmnet forwards to a guest it has heard
from. A guest that only ever listens is never heard from, so even addressed
correctly it stays unreachable: the NFS server comes up and waits, and the host
cannot open a connection to it. The host's ARP entry for the guest stays
`(incomplete)`.

**Change.** The MAC vmnet reports is parsed when the helper starts and given to
`krun_add_net_unixgram` in place of a random one. gvproxy is unaffected: it is a
user-mode stack that answers for whatever address the guest picks, so where no
vmnet helper ran, a random address is still generated. In the guest, the
interface announces itself once it is configured, by gratuitous ARP where
`arping` is present and otherwise by pinging the gateway; one frame out is
enough, and neither command's result is examined.

**Verification.** With the patch, a host-initiated TCP connection to the guest
succeeds, `ping` from the host is answered, and an NTFS volume mounts through
vmnet end to end. Without it, the same volume reaches "No route to host" every
time.

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

## krun-devices-raw-device-flush.patch

The guest is told the block device has a cache barrier, and on a raw device the
host had already decided never to honour it. `CacheType::auto()` returned
`Unsafe` for any path beginning `/dev/rdisk`, and `Unsafe` is documented in that
same file as "Flushing mechanic will be advertised to the guest driver, but the
operation will be a noop" -- the FLUSH arm of the worker returns `Ok(0)` without
touching the disk. A physical drive is exactly what reaches that branch, since
the engine opens drives through `/dev/rdiskNsM`.

The justification given is that `/dev/rdisk*` does not support flush/sync, which
is true of plain `fsync(2)` and is not a reason to answer a barrier with a
no-op. So every path now gets `Writeback`, and the FLUSH arm tolerates a device
that genuinely refuses to sync rather than turning that into a failed request --
otherwise every barrier becomes an I/O error and nothing mounts.

WHAT IT DOES NOT FIX, WHICH IS WHY IT IS DESCRIBED CAREFULLY

It does not make `fsync` durable. Measured on a real drive with the patch in:
8 MB written with `dd conv=fsync`, verified byte-for-byte on the mount, the
machine then killed -- and the file is still gone afterwards, exactly as before.

So the data is being lost above this layer, inside the guest: nfsd answers the
NFS COMMIT before ntfs3 has put it on `/dev/vda`. This patch closes the half of
the chain that was provably broken and leaves the half that is still broken
plainly visible. It is verified harmless -- 1 GB copied byte-identical at
7.0 MB/s, the same as without it -- and it is not claimed to fix the symptom.

## linux-nfsd-commit-is-durable.patch

**Defect.** An NFS COMMIT that nfsd had answered did not mean the data was on
the disk. The macOS client writes UNSTABLE and then sends COMMIT, and takes
the reply as its writes being durable. nfsd answers by calling
`vfs_fsync_range()` over the client's range and nothing else, and on ntfs3 that
is `generic_file_fsync`, which does not reach the volume metadata that
`syncfs(2)` writes. Measured on a real drive on 2026-09-10: after a 32 MiB
write and fsync from the Mac, 464 kB was still dirty in the guest. An fsync of
that one file inside the guest cleared 208 kB of it, and syncfs of the volume
cleared the other 256 kB.

This is the half `krun-devices-raw-device-flush.patch` left visible: that one
makes the host honour the guest's flush, and this one makes the guest flush
before it answers.

**Change.** `nfsd_commit()` syncs the file's filesystem whatever the export
asks for, exactly as `syncfs(2)` does: `sync_filesystem()` with `s_umount` held
for reading. It then flushes the device, so what the sync wrote is behind the
barrier and not only in the drive's cache. A writeback error, the file's and
then the filesystem's, is told to the open file once, as `fsync(2)` and
`syncfs(2)` tell it, and changes the write verifier, so that the client writes
again what it had been told was safe. A failure of the sync itself goes
through the switch that was already there and does the same. The clamp of the client's range to
`s_maxbytes` goes, with nothing left to feed.

On an async export nfsd also turned a stable write unstable while telling the
client it was stable, so a client writing synchronously sent no COMMIT at all,
and `commit_metadata()` did nothing, which answered a rename before it was on
the drive. A stable write is now written through on any export, as `fsync(2)`
writes a file: its data and inode, then a flush. The rest of what a new file
changes -- its directory entry, its clusters in the volume's bitmap -- is not
synced with it, because that takes a sync of the whole filesystem: 500 files of
4 KiB took 32.6 s to copy onto the test stick that way, against 14.0 s without
it and 11.0 s onto a native stick. It is written by the guest's writeback,
which vmproxy has run every second, and is behind a flush only at the next
COMMIT, rename or stable write. A rename on an async export syncs the
filesystem as a COMMIT does, once its locks are dropped, and fails only on an
error that sync met. A create, remove or attribute change is answered before it
is on the drive, and a drive that loses power before the next flush can come
back without it. The read-only parameter `nfsd.commit_is_durable` says a kernel has
all of this, and `vmproxy-writes-commit-at-commit.patch` exports async only
where it finds it.

**The kernel it applies to.** Not libkrunfw's own. anylinuxfs 0.19.0 takes
its `libexec/Image` from the `v6.12.62-rev1` release of `nohajc/libkrunfw`, a
fork of libkrunfw v5.1.0 with two more patches, a 16K-page config carrying more
filesystems, and OpenZFS 2.4.0 grafted into the tree as a module. The `Image`
in that release is byte for byte the one the bottle ships, and the fork's
config is byte for byte what the guest reports in `/proc/config.gz`; it is
kept here as `linux-6.12.62-guest.config`. `scripts/build-guest-kernel.sh`
rebuilds that kernel from those pins, applies this patch after the fork's
twenty-three, and refuses to write an Image if olddefconfig moves a line of the
config, if the config embedded in the result is not that config, or if the
result lacks a call one of its patches adds: `nfsd_commit` and `nfsd_rename`
reaching the filesystem sync, and `ni_remove_name` keeping the names it
removes. It applies the patches it names, not every `linux-*` file here, and
writes their names to `Image.patches` beside the Image, for `vendor-engine.sh`
to add to the record.

**Verification.** Built on 2026-09-11 in the pinned bookworm container with
ten jobs, `make Image` in 147 s, with no warning from a patched file.
olddefconfig changed nothing, the config embedded in the result is the pinned
one byte for byte, and every call the patches add is in the Image.

On the BitLocker test stick, booted with that Image, exported async, the
guest writing back every second (its log reads `dirty_writeback_centisecs 100`
and `dirty_expire_centisecs 100`) and the client writing unstably:
`scripts/kill-durability.sh` wrote 8 MiB with `conv=fsync`, killed the machine
as soon as fsync returned, and opened the drive again, and the file was
byte-identical. A Finder copy of 500 files of 4 KiB took 14.5 s, against
11.0 s onto a native exFAT stick.

Built without this patch and named as the fork names it, the result is not the
shipped Image byte for byte, and one thing accounts for all of it: the kernel
headers archive the kernel embeds (`CONFIG_IKHEADERS`). The shipped one was
generated from the config before the fork enabled NFS, SMB and F2FS, lacks
eight netfilter headers whose names differ from others only in case, and
carries a `zfs_config.h` configured for userspace too. With that archive put in
place of this build's and the kernel relinked, the result is identical to the
shipped Image. Everything else about the recipe is the original.

## linux-ntfs3-readdir-survives-deletion.patch

**Defect.** Finder deletes a folder as it lists it, and on a BitLocker drive it
stopped with "The operation can't be completed because some items had to be
skipped", leaving files behind. ntfs3 hands out readdir positions that are
byte offsets inside an index block and walks the blocks in the order they lie
on disk. Removing an entry moves the ones after it down, and rebalancing moves
entries between blocks, so a position handed out before a removal points past
entries nobody has read. A first fix restarted the listing after any removal,
which handed Finder entries it had already removed, and it stopped with the
same message on removing one twice.

**Change.** A position names the entry the listing goes on from: bit 62 set, a
30-bit hash of its name, and its MFT record number. The listing walks the index
in name order, and to go on from a position it looks the name up again: in the
inode when that is in memory, in the MFT record read directly when not, and,
when the entry has been removed since, among the last 4096 names removed from
that directory, which each directory now keeps. The record is read rather than
the inode made, because `ntfs_iget5()` given a stale sequence number marks a
live inode bad. Whatever was created or removed meanwhile, nothing is skipped
and nothing comes twice. Only a position older than 4096 removals is lost; that
is logged, and the listing starts again. The index is walked by this patch's
own code, since `indx_find_sort()` reads a subnode into the node it came from
and frees nodes without their buffers. Directories get an llseek that accepts
positions past `s_maxbytes`.

**Verification.** On the BitLocker test stick on 2026-09-11,
`scripts/listing-survives-deletion.sh` made 3,000 files and listed and removed
them at once: 3,000 listed, none twice, none already gone, none left. With
files created while it listed, every one of the 3,000 originals came exactly
once. Finder then deleted folders of 500, 5,002 and 10,538 files with no error,
and the engine log recorded no lost position. The same 500-file delete stopped
at 76 files before this patch.

## vmproxy-writes-commit-at-commit.patch

**Defect.** A sync export makes nfsd sync every create, remove and attribute
change before answering it: 29 ms a create and 10 ms a remove on the BitLocker
test drive, against none with the export async. That is the whole cost of
copying many small files, of deleting a folder, and of Finder clearing up a
cancelled copy.

**Change.** The export is async when `/sys/module/nfsd/parameters/commit_is_durable`
exists, which only a kernel with `linux-nfsd-commit-is-durable.patch` has, and
sync otherwise, so a guest booted with the stock `Image-4K` an f2fs volume gets
is exported as before. The options chosen are printed to the engine log.
`vendor-engine.sh` also refuses to package this patch without the kernel's.

**Verification.** On the BitLocker test stick on 2026-09-11, booted with the
kernel carrying `linux-nfsd-commit-is-durable.patch`, the engine log reads
`exporting rw,async,no_subtree_check,all_squash,anonuid=0,anongid=0,insecure`.
A Finder delete of 10,538 files took 14.1 s.

