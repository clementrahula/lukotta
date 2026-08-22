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

## Fixed VHD already works

**No code at all.** A fixed VHD is the raw disk followed by a 512-byte footer.
Every partition table and superblock sits at its natural offset, and the trailing
footer is simply ignored.

Tested: a 320 MB btrfs image with a proper `conectix` footer appended is listed
and mounted by the engine as it stands.

    0:   btrfs LUKOTTAPLAIN   +335.5 MB   fixed.vhd

All that is missing is for the app to accept the extension and hand it over as
raw. **That is an afternoon, not a project**, and fixed VHDs are what most
"export this VM" flows produce.

## What each of the others costs

A read-only driver in imago needs five things: `format()`, `size()`, `probe()`,
`collect_storage_dependencies()`, and `get_mapping()` — which answers, for a
guest offset, either `Raw { storage, offset }` or `Zero`. For comparison, the
VMDK driver is 743 lines and raw is 379.

| Format | Shape | Work |
| --- | --- | --- |
| **VHD, fixed** | Raw plus a trailing footer | **None.** Already works; the app just has to offer it |
| **VDI** | Header, then a flat block map of 4-byte indices | ~200 lines. The simplest real mapping there is |
| **VHD, dynamic** | Footer, header, BAT of sector offsets, per-block bitmap | ~250 lines. The bitmap makes partial blocks fiddly |
| **VHDX** | Header pair, **log that must be replayed**, region table, metadata region, BAT with three states, 1 MB alignment | ~600+ lines and the only one with real risk. Skipping log replay silently returns stale data on an image that was not cleanly closed — the kind of bug that looks like corruption |

## What I would do

1. **Ship fixed VHD now.** It works; the app only has to accept `.vhd` and pass
   it through as raw. Guard it by checking for the `conectix` footer and a disk
   type of 2, so a dynamic VHD is refused by name rather than mounted as
   nonsense.
2. **VDI, then dynamic VHD**, as imago drivers, behind the same
   `[patch.crates-io]` machinery that already carries our anylinuxfs patch.
   Upstreamable, and worth offering upstream rather than carrying.
3. **VHDX last, or never.** It is most of the work and all of the risk, and it
   is the format most likely to arrive dirty from a running VM. Refusing it with
   a clear sentence is a defensible product decision.

## The rule that keeps applying

Every non-raw format can name other files, and libkrun opens them. qcow2 has
backing files; VMDK names its extents; VHD dynamic and VHDX both have parent
locators for differencing disks. **Each new format needs its own check before
the engine is told anything** — refuse a differencing VHD, refuse a VHDX with a
parent locator — exactly as `Qcow2Header.namesAnotherFile` and
`VmdkDescriptor.namesAFileElsewhere` already do.
