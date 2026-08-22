# The remaining virtual machine formats

VHD, VHDX and VDI: what it would take, with no conversion and no copying.
Everything below was tested against the engine and guest that ship today.

---

## The four layers, all of them ours to change

A disk format travels through four crates, and **every one is built from source
in our build**:

    anylinuxfs   DiskFormat::{Raw, Qcow2, Vmdk}   → u32
      libkrun    krun_add_disk2(disk_format)      → ImageType
      krun-devices  ImageType::{Raw, Qcow2, Vmdk} → imago driver
        imago    the format readers themselves

`scripts/build-engine.sh` already patches the first. The other three are ordinary
crates.io dependencies, so `[patch.crates-io]` against local forks reaches them.
There is no prebuilt binary in the way and nothing to reverse-engineer.

## The guest cannot do it — tested, not assumed

The obvious idea is to let the Linux side decode the format, since it has
tooling. It does not work, and here is exactly why:

| Route | Result |
| --- | --- |
| `qemu-nbd` → `/dev/nbd0` | **No nbd driver in the kernel.** `modprobe nbd` says "not found in modules.dep" |
| `qemu-storage-daemon --export fuse` | **Not compiled in.** Alpine's build answers "Parameter 'type' does not accept value 'fuse'" |
| `nbdfuse` from libnbd | **Not packaged.** Alpine's `libnbd` ships nbdcopy, nbdinfo, nbdsh — no nbdfuse |
| libyal FUSE tools (`vhdimount`) | Not in Alpine at all |
| `nbdcopy` to a scratch file | That is conversion, and it copies |

The guest *does* have FUSE and loop devices — `losetup -f` works, `fuse` and
`fuseblk` are in `/proc/filesystems` — so the shape of the idea is sound. What
is missing is any packaged tool to bridge a format to a file. Supplying one
means either building qemu with FUSE ourselves or rebuilding libkrunfw to add
the `nbd` driver, and a kernel rebuild is the same wall that rules out
FileVault 2.

Alpine's `qemu-img` does read `vdi vhdx vmdk vpc`, which is what makes this
frustrating rather than impossible: the knowledge is right there, with no way to
present it as a block device.

**So the format readers belong in imago**, which is where qcow2 and VMDK already
live, and which we can build.

---

## Fixed VHD already works — and is now shipped

**No code in the engine at all.** A fixed VHD is the raw disk followed by a
512-byte footer. Every partition table and superblock sits at its natural
offset, and the trailing footer is simply ignored.

Tested: a 320 MB btrfs image with a proper `conectix` footer appended is listed
and mounted by the engine as it stands.

    0:   btrfs LUKOTTAPLAIN   +335.5 MB   fixed.vhd

Shipped in `Vhd.swift`: the footer is read, the disk type checked, and the file
handed over as raw. A dynamic VHD (type 3) and a differencing one (type 4) are
refused by name rather than served as gibberish, as is a VHDX, and so is a file
whose footer claims more disk than the file holds. `scripts/make-vhd.py` writes
both kinds, and the end-to-end run mounts the fixed one and refuses the dynamic
one. Fixed VHDs are what most "export this VM" flows produce.

## What each of the others costs

A read-only driver in imago needs five things: `format()`, `size()`, `probe()`,
`collect_storage_dependencies()`, and `get_mapping()` — which answers, for a
guest offset, either `Raw { storage, offset }` or `Zero`. For comparison, the
VMDK driver is 743 lines and raw is 379.

| Format | Shape | Work |
| --- | --- | --- |
| **VHD, fixed** | Raw plus a trailing footer | **Done.** Needed no engine change at all |
| **VDI** | Header, then a flat block map of 4-byte indices | **Done.** 380 lines with the checks and the builder |
| **VHD, dynamic** | Footer, header, BAT of sector offsets, per-block bitmap | **Done.** 400 lines, in the same driver as the fixed kind |
| **VHDX** | Header pair, **log that must be replayed**, region table, metadata region, BAT with three states, 1 MB alignment | ~600+ lines and the only one with real risk. Skipping log replay silently returns stale data on an image that was not cleanly closed — the kind of bug that looks like corruption |

## What I would do

1. ~~**Ship fixed VHD now.**~~ *Done.* It works; the app only has to accept
   `.vhd` and pass it through as raw.
2. ~~**VDI, then dynamic VHD**, as imago drivers.~~ *Done.* Both are in
   `patches/imago-vdi-and-vhd.patch`, built in through `[patch.crates-io]`
   alongside the anylinuxfs patch, with `krun-devices` taught to ask for formats
   3 and 4. Worth offering upstream rather than carrying.
3. **VHDX last, or never.** It is most of the work and all of the risk, and it
   is the format most likely to arrive dirty from a running VM. Refusing it with
   a clear sentence is a defensible product decision.

## What it took, in the end

Four layers, as expected, and no conversion anywhere:

    .vdi / .vhd  →  anylinuxfs DiskFormat  →  u32 3 or 4  →  krun_add_disk2
                 →  krun-devices ImageType →  imago driver

libkrun itself needed nothing: `krun_add_disk2` passes the number straight
through to the enum in krun-devices.

Checked in both directions, because a reader and a writer that share one
misunderstanding agree with each other and nothing else:

- images written by `qemu-img` (VDI, dynamic VHD, fixed VHD) read back byte for
  byte identical to the raw disk they were made from, and mount through the app;
- images written by `scripts/make-vdi.py` and `scripts/make-vhd.py` are read by
  `qemu-img compare`, which finds them identical to the same raw disk.

The end-to-end run uses the ones written here, so it needs neither qemu nor
VirtualBox installed.

## The rule that keeps applying

Every non-raw format can name other files, and libkrun opens them. qcow2 has
backing files; VMDK names its extents; VHD dynamic and VHDX both have parent
locators for differencing disks. **Each new format needs its own check before
the engine is told anything** — refuse a differencing VHD, refuse a VHDX with a
parent locator — exactly as `Qcow2Header.namesAnotherFile` and
`VmdkDescriptor.namesAFileElsewhere` already do.
