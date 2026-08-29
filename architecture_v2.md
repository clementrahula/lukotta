# Lukotta v2: making a drive feel like a Finder volume

The design record for the v2 branch -- the FSKit filesystem extension and the
NTFS implementation behind it. Written as the work happened, so it reads
forwards: what was measured, what that ruled out, and what was built next. The
measurements are all from one Mac and are labelled as such.

It is kept because the code says what it does and this says why -- why there is
no journal and is not going to be one, why the dirty flag goes to two places in
one order and comes off in the other, why a name is compared through the
volume's own table rather than the language's.

## The target, in full

A drive opened by Lukotta must be indistinguishable from any other volume in
Finder. Specifically, all of these, not a subset:

1. **Deletions are instant and never error.** One file or a million. No
   "some items had to be skipped". Trash behaves as it does on a local disk.
2. **Copying runs at no less than 80% of direct-attached speed**, both
   directions, for large files and for large trees of small files.
3. **Any number of files, no timeouts, no errors.** A 500,000-file photo
   library copies without incident.
4. **Scales to a dozen drives open at once.**
5. **Realistic hardware cost.** It cannot take half the machine's RAM or CPU.
   A dozen drives must not mean a dozen fat virtual machines.
6. **Rock stable.** No wedged mounts, no drives vanishing mid-copy, no
   recovery rituals.
7. **Free, and GPL-compatible.** Licence is a hard constraint, not a
   preference. Anything that requires a proprietary component is out.

Nothing else is off the table: a different transport, a different filesystem
interface, kernel extensions, FSKit, a rewritten guest, no guest at all.

## What is there today

macOS app. Opens BitLocker, LUKS, NTFS and other Linux-supported filesystems by
booting a Linux microVM, mounting the filesystem inside it, and re-exporting it
to the host over NFS so it appears in Finder.

- microVM: **libkrun 1.19.3** (nohajc fork), guest kernel **6.12.62**, Alpine
  rootfs, via the vendored **anylinuxfs 0.19.0** engine.
- Networking: **gvproxy** (gvisor-tap-vsock v0.8.9), user-mode TCP/IP over a
  unixgram socket pair to krun's virtio-net.
- Guest server: **in-kernel nfsd**, thread count = vCPU count.
- Host mount: **NFSv3 over TCP on loopback**.
- The app gives each VM **1024 MiB** and **2 vCPUs**
  (`MountScript.VirtualMachine`).
- Control channel is **virtio-vsock**, separate from the data path.

## Measurements taken on this machine, 2026-08-27/28

All on an M-series Mac, 10 cores, against a 40 GB NTFS volume in a sparse image
served by the real app, unless noted.

**Deletion, 6000 files of 512 bytes, `rm -rf`:**

    over NFS, 2 nfsd threads          5000 ms   (1200 files/s)
    over NFS, 8 nfsd threads          4172 ms   (1438 files/s)
    over NFS, async export            4550 ms
    inside the guest, same volume         0 ms

The last line is the important one. The entire cost is the NFS path: roughly
**0.7 ms per unlink**, serial, because `rm` unlinks one at a time and NFSv3 has
no bulk operation. Raising server threads barely helps because the client is
not issuing concurrent requests. An async export does not help because the
guest is not what is waiting.

**Finder's delete additionally fails outright** with "some items had to be
skipped": it tries to move to Trash first, the volume has no usable
`.Trashes`, and it falls back to per-file deletion. A rename into a
hand-created `.Trashes` took **8 ms** — but creating one writes to a drive the
app opened, which the app does not do.

**Copying a 130 GB photo library** (real hardware, BitLocker → dm-crypt →
ntfs3 → NFS): started at ~53 GB/hour with 91 KB average writes, dropped to
**7 GB/hour with 33 KB average writes** once it reached small files. Cost is
per-file round trip, not per byte.

**Stalls.** With `deadtimeout=45` (the engine's default) a drive that goes
quiet for 45 s is unmounted by macOS, and the engine shuts the microVM down
when its share disappears — the copy ends and cannot resume. Raised to 300 in
1.21.0, which survives; verified twice under a starved backing store. Removing
`deadtimeout` entirely is worse: the mount never recovers.

**Guest memory** reached **1211 MiB against a 1024 MiB allocation** under
sustained writes to a large volume, then drained as it flushed. Multiply by a
dozen drives and the current design does not fit constraint 5.

## Questions worth answering

Not leading questions — the answer may be that the whole transport changes.

- **FSKit** (macOS 15+). Apple's user-space filesystem API, no kext, no
  network layer, no per-file round trip to a VM. `TODO.md` records that
  third-party extensions were broken on 26.1/26.2 (`fskitd` rejecting
  unprivileged clients, breaking Apple's own sample). Is that fixed now? What
  does an FSKit module cost to write for ntfs3/LUKS/BitLocker, and can the
  existing Linux drivers be reached from one, or must the filesystem code be
  reimplemented or ported?
- **virtio-fs** instead of NFS. It is designed exactly for host↔guest file
  sharing and avoids the network stack entirely. Can libkrun expose a virtiofs
  device backed by a guest mount, and can macOS consume it? What is the
  per-operation cost compared with the 0.7 ms measured over NFS?
- **NFSv4.1+** instead of v3: compound operations batch multiple ops per round
  trip, which is exactly what per-file deletion needs. Does macOS's client
  support enough of it, and does Linux nfsd deliver the batching in practice?
- **A different guest topology.** One VM shared by all drives rather than one
  per drive, addressing constraint 5. What breaks — isolation, failure
  domains, the ceiling of three loopback addresses?
- **No guest at all.** Are there GPL-compatible user-space implementations of
  NTFS, ext4, btrfs, LUKS and BitLocker that could run natively on macOS
  behind FSKit? ntfs-3g is GPL. cryptsetup is GPL. What is missing?
- **Trash.** How do other volumes get working Trash, and what exactly does
  Finder require before it will use it rather than deleting per file?
- **Where the 0.7 ms actually goes.** Client stack, gvproxy, virtio, guest
  kernel, ntfs3? Without that breakdown, any transport change is a guess.

## Constraints on any answer

- GPL-compatible and free. macFUSE's current licence must be checked before it
  is proposed.
- Must handle BitLocker and LUKS, which is why a Linux kernel is there at all.
- The app is signed, notarised and distributed outside the App Store; a kext
  or a system extension has entitlement and user-approval consequences that
  need stating.
- Whatever is proposed must have a migration path from what ships today.

## Design

Written 2026-08-28, on this machine (macOS 26.6.1, SDK 26). Markers as in
nfs-stall.md: **[E]** established by evidence here, **[S]** sourced (URL),
**[I]** inference.

### 1. Where the 0.7 ms per operation actually goes

New baselines measured today (read-only for every drive; nothing mounted,
no VM started):

    loopback TCP round trip, 128 B, TCP_NODELAY     22 µs median, 55 µs p95   [E]
    unixgram socketpair round trip, 128 B            7 µs median              [E]
    unix stream socketpair round trip, 128 B         6.5 µs median            [E]
    loopback TCP round trip, 32 KiB                200 µs median              [E]
    APFS, internal SSD: unlink                      59 µs median, 89 µs p95   [E]
    APFS: rm -rf of 6000 × 512 B files             590 ms  (≈98 µs/file)      [E]
    APFS: create 6000 × 512 B files                762 ms  (≈127 µs/file)     [E]

Putting these beside the existing measurements:

- The guest side is free. `rm -rf` of the same 6000 files inside the guest
  measured ~0 ms; ntfs3 unlinks in page cache cost single-digit µs. [E]
- The kernel transport primitives are nearly free: the whole
  host-kernel-TCP + two-unixgram-hop budget is ≤ 40 µs of the 700. [E]
- Server dispatch is minor: nfsd 2 → 8 threads moved 5000 → 4172 ms, 17%,
  because the macOS client issues one request at a time. [E]

So ≥ 600 of the 700 µs live in exactly two places: **gvproxy's user-mode
netstack traversal** (a Go gVisor TCP/IP stack crossed twice per RPC, once
per direction, plus scheduler wakeups) and **the macOS NFS client's own RPC
turnaround** (biod wakeup, XID matching, credential and attribute handling —
all serial). Which of the two dominates is the one genuinely open number.
External evidence points at the transport as the larger half:

- Upstream anylinuxfs got **~2× write throughput by replacing gvproxy with
  vmnet-helper** and nothing else
  ([releases](https://github.com/nohajc/anylinuxfs/releases), 0.14.0). [S]
- Checksum/TSO offloading on the virtio-net path is worth another **4–5×**
  ([anylinuxfs#127](https://github.com/nohajc/anylinuxfs/issues/127),
  [vmnet-helper performance](https://github.com/nirs/vmnet-helper/blob/main/docs/performance.md),
  needs [libkrun#556](https://github.com/containers/libkrun/pull/556); the
  offload path is only symmetric on macOS ≥ 26.2). [S]
- gVisor's netstack has a documented, unresolved send-buffer stall in
  exactly this topology
  ([gvisor#10243](https://github.com/google/gvisor/issues/10243)). [S]

**The discriminating experiment**, next time a VM is up (≈1 hour, no code):
(a) TCP connect + 128 B echo RTT to the guest through gvproxy, then through
vmnet-helper — the transport in isolation, both stacks; (b) `rm` of 6000
files while `nfsstat -m` samples the per-op RTT columns and tcpdump stamps
the wire — syscall→wire and wire→reply split the client's share from the
transport's; (c) the same unlink stream from a Linux NFS client in a second
VM against the same server, which bounds the server+transport with a
known-concurrent client. Predicted split: 0.3–0.5 ms gvproxy, 0.1–0.2 ms
macOS client, ≤ 0.05 ms everything else. [I]

**The conclusion that matters for the architecture**: local APFS itself
costs ~60–100 µs per metadata op [E]. A perfect transport under the present
design still leaves the macOS NFS client's semantics: serial issue, network
volume in Finder, no Trash, `deadtimeout` unmounts, soft-mount short writes.
Tuning cannot cross that. The consumer has to change, not just the pipe.

### 2. Candidate architectures

**Licence ground rules first** (hard constraint 8):

| Component | Licence | Compatible with GPL-3.0-or-later app? |
| --- | --- | --- |
| macFUSE 4/5 | closed-source kext; binary redistribution with other software forbidden without written permission ([macfuse#616](https://github.com/macfuse/macfuse/issues/616), [MacPorts #70948](https://trac.macports.org/ticket/70948)) | **No. Excluded.** |
| fuse-t | proprietary freeware; commercial licence required for embedding ([License.txt](https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt)) | **No. Excluded.** |
| FSKit | macOS system framework | Yes (system-library exception) |
| libkrun (nohajc fork) | Apache-2.0 | Yes |
| anylinuxfs | GPL-3.0 | Yes |
| Linux kernel + ntfs3/ext4/btrfs/dm-crypt | GPL-2.0 (separate VM process, no linking) | Yes |
| gvisor-tap-vsock / vmnet-helper / [vmnet-broker](https://github.com/nirs/vmnet-broker) | Apache-2.0 | Yes |
| libnfs (client library) | LGPL-2.1-or-later ([COPYING](https://github.com/sahlberg/libnfs)) | Yes |
| virtiofsd (reference FUSE-server code) | Apache-2.0 / BSD-3-Clause ([gitlab](https://gitlab.com/virtio-fs/virtiofsd)) | Yes |
| nfsserve (Rust NFSv3 server) | BSD-3-Clause ([repo](https://github.com/xetdata/nfsserve)) | Yes |
| Samba | GPL-3.0 | Yes |

#### 2.1 FSKit — the front end that changes the game

Status, verified today:

- API shipped macOS 15.4; this machine's SDK marks a **V2 API level at
  macOS 26.0** (`FSKitDefines.h`) which adds `FSGenericURLResource` and
  `FSPathURLResource` — a volume backed by an arbitrary URL rather than a
  block device — plus `FSVolumeKernelOffloadedIOOperations` (kernel reads
  extents directly, block-device resources only). [E]
- Apple runs msdos, exfat and ftp through FSKit on this machine
  (`pluginkit -m -p com.apple.fskit.fsmodule`). [E] `mount -F` is a
  documented flag ("Forces the file system type be considered as an
  FSModule delivered using FSKit", mount(8) here). [E]
- The TODO.md blocker — fskitd rejecting unprivileged clients on 26.1/26.2
  ([loaf#1](https://github.com/andrewgazelka/loaf/issues/1), Dec 2025) — is
  no longer the state of the world: **macFUSE 5.2.0 (Apr 2026) ships a
  working FSKit backend supporting macOS 12–26**
  ([announcement](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html)),
  and fuse-t advertises a native FSKit backend on macOS 26+
  ([fuse-t.org](https://www.fuse-t.org/)). Two shipping third-party FSKit
  consumers is better evidence than a release note. [S]
- Two real, open bugs remain, both with workarounds:
  (1) **Physical-disk probing**: fskitd can hit EPERM opening the device
  node, and Apple's read-only NTFS kext outbids FSKit modules for
  NTFS-looking volumes (FB18230524;
  [forum 788609](https://developer.apple.com/forums/thread/788609), DTS
  acknowledged, one fix "coming" as of Apr 2026). Workarounds: chown the
  device node from a privileged helper — which Lukotta has — and note that
  a **locked BitLocker or LUKS partition does not carry an NTFS boot
  sector**, so the kext never probes it (TODO.md already planned this
  test). (2) **Stale extension UUIDs after app updates**
  ([forum 804432](https://developer.apple.com/forums/thread/804432),
  FB20790194): re-register the appex with lsregister/pluginkit at launch —
  Lukotta updates via Sparkle, so this goes next to the existing
  helper-staleness handling. [S]
- Cost profile: a Swift appex implementing `FSUnaryFileSystem` +
  `FSVolume.Operations` (+ Xattr, OpenClose, ReadWrite, Rename protocols).
  The FSKit module entitlement is self-service; macFUSE ships one outside
  the App Store today. No kext, no user security downgrade. [S]
- What it buys: the volume is **local**. Finder trash machinery engages,
  no network-volume badge or behavior, no macOS NFS client in the loop at
  all — `deadtimeout`, soft-mount short writes, dead-mount sweeps, the
  wedge taxonomy of nfs-stall.md: all structurally gone. We answer every
  VFS op ourselves, which is what makes requirements 1, 2 and 7 reachable
  at all.
- What it forecloses: macOS 15.0–15.3 (app already requires 15+; FSKit
  needs 15.4; the V2 URL-resource route needs 26). Ship the NFS path as
  the fallback on 15.x for one release cycle, or raise the floor.

#### 2.2 virtio-fs — dead on the host side

virtio-fs is FUSE over virtio shared memory. macOS has a virtio-fs
**driver only when macOS itself is the guest** of Virtualization.framework
(`VZVirtioFileSystemDeviceConfiguration`,
[Apple docs](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration));
on bare metal there is no virtio transport and no way to present one, and
libkrun's `krun_add_virtiofs` shares **host directories into the guest**
([libkrun README](https://github.com/containers/libkrun)) — the wrong
direction for us. There is no macOS virtio-fs client to mount a guest
export. **Excluded as a literal transport.** But its *shape* — FUSE
semantics, no network stack, host consumes a guest-served tree — is
exactly what §3 builds over vsock instead.

#### 2.3 NFSv4.1 — the client isn't there

The macOS client supports **NFSv4.0 only** ("Currently NFSv4 is the highest
supported version with a minor version of zero",
[mount_nfs(8)](https://ss64.com/mac/mount_nfs.html)). No 4.1 sessions, no
pNFS. And COMPOUND does not batch across syscalls anyway: `rm` still issues
one compound per unlink, so the per-file round trip survives. v4.0 on macOS
is also the least-exercised path in an already stagnant client. **Excluded:
cost near zero, but it buys ~nothing against requirements 1, 2, 6, 7.**
(The guest side already serves 4.2 — `DEFAULT_NFS_VERSION='4.2'` in
entrypoint.sh — so this was only ever a mount-option change; it was worth
pricing, and the price of keeping it is higher than the win.)

#### 2.4 SMB via Samba in the guest

Samba is GPL-3.0, the macOS SMB client is the best-maintained network
client on the platform, and server-side copy (`FSCTL_SRV_COPYCHUNK`) would
accelerate on-volume duplication. But an SMB mount is still a **network
volume**: no Trash (Finder deletes immediately), per-file round trips
remain, the volume wears the server icon, and stalls are still the
client's timers against our server. It fails requirements 1 and 2 by
construction. **Excluded as the primary; not worth a stage.**

#### 2.5 One shared guest VM instead of one per drive

Orthogonal to the transport, and adopted in §3. Today each drive costs a
VM sized 2 vCPU/1024 MiB whose RSS was measured at 1211 MiB under load
[E]. libkrun cannot hotplug virtio-blk devices (no hotplug in
[libkrun.h](https://raw.githubusercontent.com/containers/libkrun/refs/heads/main/include/libkrun.h)),
so a long-lived shared VM must attach late-arriving drives another way:
serve the raw device **from the host over vsock into the guest's nbd
client** (`CONFIG_NBD` goes into the libkrunfw kernel build, which is
already a custom nohajc build we patch). Per-drive dirty-page ceilings via
`/sys/class/bdi/<dev>/max_ratio` keep one slow drive from absorbing the
shared page cache — the exact amplifier in the 2026-08-27 incident.
What it costs: engine surgery (mount/unmount become attach/detach), and a
shared failure domain — one guest oops takes down every drive. Mitigation
in §3: attachment is policy, and a flaky drive can still get a private VM
from the same code path.

#### 2.6 No guest at all — GPL implementations behind FSKit

The inventory: NTFS r/w — ntfs-3g (GPL-2.0+); ext4 — lwext4 (GPL-2.0,
partial journalling); btrfs — **no credible user-space read-write
implementation exists** (btrfs-fuse is read-only); LUKS — cryptsetup
(GPL-2.0+) formats/keys, but the dm-crypt data path is kernel code that
would need reimplementing (the crypto itself is easy; the sector-IV zoo is
not); BitLocker — libbde (LGPL-3.0+), read-write is marked experimental.
The honest cost is "reimplement or port the four hardest filesystems",
i.e. years, and btrfs write support simply does not exist to port.
**LKL** (the Linux kernel as a library, [lkl/linux](https://github.com/lkl/linux))
would give the real drivers natively, but upstream supports POSIX/Windows
x86-64 hosts, has no macOS/arm64 host port, and its mainlining effort
stalled ([LWN: Unifying LKL into UML](https://lwn.net/Articles/825100/)).
**Not the primary.** The saving grace: behind the FSKit module of §3 the
backend is an implementation detail, so a native ntfs-3g backend for the
single most common format can be added later without touching the front
end — and a 1-week LKL-on-macOS spike stays on the long-term list.

#### 2.7 Kext / DriverKit

A third-party kext needs a kext entitlement Apple rarely grants plus a
user trip through Recovery to lower security on Apple Silicon — that is
not "indistinguishable from any other volume" for the person installing
it. DriverKit's block-storage family could at most present a *decrypted
block device*, which only helps where macOS has its own writable driver
for what's inside (exFAT/FAT); it has none for NTFS-write, ext4 or btrfs.
**Both excluded.**

#### 2.8 Two shipping projects that already do parts of this

Found 2026-08-28. Neither can be depended on, and both are evidence the
FSKit route works on real hardware today.

**NTFSKit** ([whereteam/ntfskit](https://github.com/whereteam/ntfskit)) —
NTFS read/write on macOS 15.4+ Apple Silicon through FSKit, with automatic
mounting of external drives and disk images. Its driver is built on
libntfs-3g, so the same engine Lukotta already runs in the guest, and the
interesting part is what it does with it: **kernel-offloaded I/O**, where
the module maps storage extents and the kernel writes the file data to disk
itself, so bulk data never crosses into user space. Reported ceiling
572 MB/s. It detects a Windows hibernation image and falls back to
read-only, which is the behaviour Lukotta wants too. It also confirms the
cost that survives every design: the volume has to be enabled by hand in
System Settings once.

**xlinuxfs** ([HuanchuanTech/xlinuxfs](https://github.com/HuanchuanTech/xlinuxfs))
— ext2/3/4 read/write and XFS and btrfs read-only behind FSKit, with **no
virtual machine at all**: it embeds LKL, the Linux kernel as a library, as
a native Mach-O object and routes FSKit operations through a C bridge onto
`lkl_sys_*` calls. Verified on macOS 26.5. Auto-mounting works with the app
not running.

**This corrects §2.6.** That section says LKL has no macOS/arm64 host port
and treats it as a long-term spike. xlinuxfs is that port, working, on this
machine's OS. Whether it is upstreamable or a private fork is worth
establishing, because "the real Linux drivers, natively, no guest" removes
the microVM from the picture entirely — and with it every millisecond §1
attributes to crossing into it.

**Neither can be taken.** The NTFSKit driver is GPL-2.0 (its UI is
proprietary), and xlinuxfs is GPL-2.0 as well, since it embeds kernel code.
Lukotta is conveyed under GPL-3.0-or-later. GPL-2.0-**only** and
GPL-3.0-or-later cannot be combined in one work in either direction: neither
licence permits relicensing to the other's terms. This is not the situation
of ntfs-3g or cryptsetup, which are GPL-2.0-**or-later** and so may be
conveyed under GPL-3.0. Before either is dismissed on licensing alone, the
actual headers are worth reading rather than the README: "GPL-2.0" in a
README is frequently GPL-2.0-or-later in the files, and that one word
decides it.

What is usable regardless of licence: the shape of the FSKit module, the
kernel-offloaded extent-mapping design, and the demonstration that both
approaches pass Apple's review and run on shipping macOS.

#### 2.9 FSKit entitlements: what it actually takes to ship one

Established 2026-08-28 from Apple's own documentation and from projects
shipping today. The question was whether the entitlement is obtainable at
all for a Developer ID app outside the App Store.

**One key, on the extension, not the app:**
`com.apple.developer.fskit.fsmodule`, Boolean true, macOS 15.4+. Xcode calls
the capability "FSKit Module". It travels with App Sandbox; the host app
needs no FSKit entitlement of its own.

**It is *restricted*, not *managed*.** Apple's three tiers are: unrestricted
(no profile), restricted (a provisioning profile must authorise it, and any
paid member can make one), managed (apply to Apple and be approved, as with
Endpoint Security and DriverKit). FSKit sits in the middle. The evidence:
Apple's
[supported capabilities table for macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
lists "FSKit Module" with the **Developer ID** column ticked and no
development-only asterisk; the
[entitlement's own page](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
carries none of the "you must request this entitlement from Apple" language
that the Endpoint Security page does; and Apple's capability-request pages
do not mention FSKit at all.
[Quinn's description of the three tiers](https://developer.apple.com/forums/thread/735356).

Not verified from outside: that the capability appears on the App ID's
**Capabilities** tab rather than its **Capability Requests** tab. Two
minutes in the developer portal settles it, and it is worth doing before any
v2 work starts.

**Developer ID distribution is proven.**
[indragiek/GHFS](https://github.com/indragiek/GHFS) ships a notarised,
Developer-ID-signed DMG carrying that entitlement, with Sparkle updates —
the same channel Lukotta uses. So the model is not App Store only.

**Provisioning.** Each bundle claiming the entitlement carries its own
`embedded.provisionprofile`, inside the `.appex` rather than only the app.
A Developer ID profile made after 22 February 2017 is valid for 18 years,
and Xcode regenerates one on every build, so nothing needs renewing per
release. Gatekeeper checks the profile at **every launch**: an expired
profile stops the app launching, though a lapsed membership does not, and
only certificate revocation breaks copies already installed.
[Apple on Developer ID expiry](https://developer.apple.com/support/developer-id/).

**The two risks that actually matter, and they are not the entitlement.**

*The toggle.* Every person must enable the module once in System Settings →
General → Login Items & Extensions → File System Extensions. Both of
xlinuxfs's open issues are paying customers for whom that switch refuses to
stick, traced to `fskitd` and `cfprefsd` caching `enabledModules.plist`;
their workaround kills four daemons together, and the app ships a repair
script that does not reliably work.

*Sparkle de-registers the extension.* On
[Apple forum thread 788609](https://developer.apple.com/forums/thread/788609),
a developer reports that after a Sparkle update `lsd` registers the appex
under a new UUID while `extensionkitservice` still holds the old one, and
the extension stops being recognised until the switch is toggled off and on
by hand. Apple's DTS confirmed there is **no public API** to force
re-adjudication, and that the `lsregister -f` plus `pluginkit -a` workaround
"shouldn't be necessary". GHFS ships its own mitigation: "Clean all stale
GHFS bundle registrations before mounting."

This is the real gate on §3, and it lands squarely on the rule that the
person using this should never be handed the technical burden. A routine
Lukotta update that silently stops the filesystem working until somebody
finds a switch they were never told about is worse than the microVM. Before
v2 is committed to, the experiment to run is: ship an FSKit module to
oneself, update it through the real Sparkle flow, and establish whether the
registration survives — and if it does not, whether it can be repaired from
inside the app without the person noticing.

### 3. Recommended architecture: FSKit front, one engine VM, vsock data plane

One sentence: **a Lukotta FSKit module presents each drive as a local
volume; its data plane is NFSv3 spoken by libnfs over a vsock/unix-socket
channel into the same in-guest knfsd that serves today, running in one
shared microVM that reaches drives over nbd-on-vsock; Trash and bulk
deletion are handled by a host-side ledger plus an in-guest purge daemon.**
gvproxy, the macOS NFS client, and per-drive VMs all retire.

#### Components

| Component | New/reused | What it is |
| --- | --- | --- |
| `LukottaFS.appex` | **new** (Swift) | `FSUnaryFileSystem`; probes BitLocker/LUKS/NTFS signatures (reuse `BootSector.swift` logic), implements `FSVolume.Operations`/`ReadWrite`/`Xattr`/`OpenClose`/`Rename` by calling FSGate; hides and synthesizes `.Trashes` from the ledger |
| `FSGate` | **new** (C/Swift wrapper) | libnfs (LGPL-2.1+) client bound to a unix socket instead of TCP — a ~100-line patch carried in `patches/` like the others; one connection per volume, requests pipelined |
| `VolumeService` | **refactor** of `Mounter`/`Engine*` | owns the engine VM(s), the ledger, passphrase flow (FIFO → root helper unchanged), reconnection policy |
| engine VM | **reused** (anylinuxfs, patched) | one long-lived microVM, 2 vCPU / 512 MiB + balloon; boots at first unlock, idles at ~0 CPU |
| block attach | **new** (small) | root helper opens `/dev/rdiskNsM`, keeps the fd, serves nbd on a unix socket; guest `nbd-client` over a `krun_add_vsock_port` channel; `CONFIG_NBD=y` added to the libkrunfw build |
| guest agent | **extend** entrypoint.sh + vmproxy | attach/detach exports (`exportfs` per drive — knfsd stays), dm-crypt/LVM assembly as today, **purge daemon**: receives paths over the existing vsock control channel, `rm -rf`s them guest-side (measured free [E]) |
| Trash ledger | **new** | per-volume-UUID table in Application Support: entries = (trash name, original path, xattrs, put-back info); the drive is never written by us |

#### The eight requirements, one by one

1. **Indistinguishable volume.** FSKit volumes on block devices mount as
   local volumes through DiskArbitration, appear on the desktop and
   sidebar, eject normally. No server icon, no network semantics. The
   module reports ownership as the opening user (what
   `--ignore-permissions` fakes today).
2. **Deletions instant, Trash works.** The volume is local, so Finder
   moves to Trash: a rename into `.Trashes/<uid>` — which the module
   answers from the ledger in ~10 µs without touching the drive. One file
   or a folder of a million is **one rename**. Empty Trash: Finder's
   per-item unlinks are ledger marks answered immediately; the purge
   daemon deletes guest-side at native speed in the background, retrying
   quietly; nothing can produce "some items had to be skipped" because
   nothing waits on the drive. Put Back works from ledger metadata.
   Direct deletes (Terminal `rm`, "Delete Immediately") run the wire:
   ~100–150 µs/op [I], at or under local-APFS cost [E].
3. **≥ 80 % of direct-attached speed.** Large files: guest virtio-blk +
   dm-crypt + ntfs3 are near-native [E: 6 MB/s incident ceiling was the
   transport/media, not the drivers]; the wire is a unix-socket stream
   (multi-GB/s kernel path, no netstack) with pipelined 1 MiB NFS
   READ/WRITEs — the 128 KiB macOS-client cap dies with the client.
   Small-file trees: create+writes+close ≈ 5 ops ≈ 0.6 ms/file plus
   pipelining ⇒ ~1500–2500 files/s against APFS-local ~2000–8000 [E][I];
   `enumerateDirectory` with attributes maps to READDIRPLUS batches.
   This is the requirement that keeps the two benchmark gates in §5.
4. **Any number of files.** No client timers, no `deadtimeout`, no soft
   short-writes: a stall blocks only the op in flight, and FSGate's
   reconnect policy (not macOS's) decides what an unreachable backend
   means. The 500k-photo-library copy is bounded by throughput, not by
   per-file failure modes.
5. **A dozen drives.** One VM total: 512 MiB + 12 × nbd server fds. The
   three-loopback-address ceiling is gone with the addresses themselves.
6. **RAM/CPU.** Worst case ≈ one VM's RSS (~600 MiB with balloon + per-bdi
   writeback caps) versus today's 12 × ~1200 MiB. vCPUs shared at 2.
7. **Rock stable.** The failure taxonomy collected in nfs-stall.md was
   macOS-NFS-client-shaped; none of it survives the client's removal.
   New failure modes and their answers: guest oops → VolumeService
   reboots the VM (~2 s [E: mounts take ~6 s today including discovery])
   and FSGate reconnects — **the FSKit mount survives a backend restart**,
   which no NFS mount ever did; drive unplug → nbd read fails, guest fs
   errors, module reports the volume offline through FSKit instead of a
   kernel-side dead mount; fskitd bugs → the two known ones have shipped
   workarounds (§2.1) plus re-registration at launch.
8. **Licences.** Every component in the table in §2 is GPL-3.0-compatible;
   the two incompatible candidates (macFUSE, fuse-t) are excluded up
   front. FSKit is a system framework.

#### Migration path — every stage ships

- **Stage 0 (weeks, pure config/engine-bump): stop paying the gvproxy
  tax.** Switch the engine's net helper to vmnet-helper on macOS ≥ 26
  (`NetHelper` is a config key; the binary already ships in
  `libexec/`), bump libkrun past
  [#556](https://github.com/containers/libkrun/pull/556) and enable
  TSO/checksum offload on ≥ 26.2; set `NFS_SERVER_THREAD_COUNT=8`.
  Expected: 2–5× throughput [S], deletion perhaps 2× [I]. The app still
  meets none of 1/2 fully — this stage is risk-free speed while the real
  work lands. Re-run the §1 experiment on both stacks while here.
- **Stage 1 (≈3 days): the two calibration spikes.** (a) Benchmark
  Apple's msdos FSKit module: FAT disk image, create/delete 6000 files,
  sequential dd — this prices FSKit's per-op and streaming ceiling with
  zero code written. (b) Minimal third-party FSKit module (Apple sample
  shape) on 26.6: mount a disk image, then a physical partition with the
  root helper chowning the device node; verify Trash engages on it.
  **These two spikes are the go/no-go gate for the whole plan** — see §4.
- **Stage 2 (4–6 weeks): FSKit volume, read-only, images first.**
  `LukottaFS.appex` + FSGate(libnfs-over-unix-socket) against the
  existing **per-drive** VM (topology unchanged — the engine already
  exposes vsock ports via krun; add `socat VSOCK-LISTEN:2049 ↔
  TCP:127.0.0.1:2049` to the entrypoint). Ship behind a per-drive toggle;
  NFS path remains the default. Container files before physical drives,
  mirroring how e2e.sh already tests.
- **Stage 3 (≈4 weeks): write path + Trash ledger + purge daemon.** Flip
  the default to FSKit for macOS 26+; NFS remains for 15.x. Requirement 2
  is done at the end of this stage.
- **Stage 4 (≈3 weeks): the shared VM.** nbd-over-vsock attach/detach,
  per-bdi writeback caps, balloon; per-drive VM stays as a policy escape
  hatch. Requirement 5/6 done.
- **Stage 5: retire** gvproxy and the macOS-NFS mount path on 26+; delete
  the dead-mount sweeps, `deadtimeout` lore, and stall watch, which no
  longer have a referent. (Keep `nfs-stall.md`; it documents why.)

Each stage leaves the previous transport working and selectable; nothing
strands a user mid-migration, and every stage is independently testable by
the existing e2e harness plus one new fixture per stage.

### 4. Fallback architecture, and the switch point

**Fallback: same backend, host-side user-space NFS server on real
loopback.** If FSKit fails its gate, keep everything behind FSGate and put
a small NFSv3 **server** (nfsserve, BSD-3-Clause, or equivalent) inside
`VolumeService`, serving 127.0.0.1 to the macOS client; it proxies to the
guest over the same vsock channel and owns the same ledger. What it
rescues: `.Trashes/<uid>` is synthesized by our server, so Finder's Trash
works even on the NFS mount (measured here: a rename into a present
`.Trashes` took 8 ms [E]); unlink/rename during Empty Trash are answered
from the ledger immediately with guest-side purge behind them; transport
is kernel loopback (22 µs RTT [E]) instead of gvproxy; we choose the mount
options, ending the soft-vs-hard and `deadtimeout` bind (a server we run
cannot vanish while the app lives, so `hard,intr` becomes safe). What it
cannot rescue: the network-volume presentation (requirement 1 is met in
behavior but not in appearance — the one residue, and the reason it is
the fallback). Cost: 3–4 weeks, nearly all shared with the primary.

**The decision point.** At the end of Stage 1: the fallback is taken if
(a) a physical-partition-backed FSKit volume cannot be mounted on current
macOS with root-helper workarounds — i.e. FB18230524-class bugs persist
with no workaround — or (b) measured FSKit ceilings land worse than
0.3 ms per metadata op or ~400 MB/s streaming (Apple's own msdos module is
the yardstick; if Apple can't go fast through fskitd, neither can we).
Either finding flips the order: ship the fallback, keep the appex on the
shelf, re-test FSKit each macOS release — the front end is the only part
that differs.

### 5. What is genuinely unknown, and the experiment that closes each

| Unknown | Experiment | Time |
| --- | --- | --- |
| gvproxy vs macOS-client share of the 0.7 ms | §1 discriminating experiment, both net helpers | 1 h with a VM up |
| FSKit per-op + streaming ceiling | Stage-1 spike (a): benchmark Apple's msdos module | ½ day |
| FSKit physical-disk mount on 26.6 with root helper | Stage-1 spike (b) | 2–3 days |
| Finder Trash engagement on a third-party FSKit volume | part of spike (b): trash a file, watch for `.Trashes` mkdir upcalls | included |
| libnfs pipelining depth over one unix socket | bench FSGate prototype against the guest, 6000 unlinks queued 32-deep | 1 day, with Stage 2 |
| nbd-over-vsock throughput vs virtio-blk | attach the same image both ways in a dev VM, dd + fio | 1 day, with Stage 4 |
| vsock/unix-socket streaming ceiling under libkrun | iperf-style test through `krun_add_vsock_port` | ½ day |
| LKL on macOS/arm64 (long-term native backend) | build spike against lkl/linux HEAD | 1 week, deferred |

The single riskiest assumption is that **fskitd on current macOS lets a
notarised, Sparkle-updated app mount a physical-disk-backed volume and
sustain real throughput**. It is also the cheapest of the big unknowns to
test — three days, before any architecture is committed — which is why it
is Stage 1 and everything irreversible comes after it.


### 6. Stage 1, first measurements: what FSKit actually costs

Measured 2026-08-28 evening on this Mac (macOS 26.6.1) with
`scripts/volume-bench.sh`: 6000 files of 512 B, plus one 800 MB file. Every row
is on the internal SSD, so the storage underneath is identical and the only
thing varying is the filesystem and who serves it.

| Volume | create | delete | write | read |
| --- | --- | --- | --- | --- |
| APFS, internal, native | 64 us/file | 48 us/file | 1667 MB/s | 3653 MB/s |
| HFS+ in a disk image, kernel driver | 85 us/file | 49 us/file | 1316 MB/s | 2151 MB/s |
| FAT32 in a disk image, **Apple's own FSKit module** | **1686 us/file** | **1186 us/file** | 949 MB/s | 1860 MB/s |
| v1 today, NTFS over NFS on vmnet | 1023 us/file | 619 us/file | 611 MB/s | -- |

All [E].

**The disk image costs nothing.** HFS+ inside one runs at 85 us/file against
APFS's 64, so the sparse-image layer is not what any of the rest is measuring.
That control matters: without it every FSKit number could have been the image.

**Apple's own FSKit module is slower than v1's NFS path**, on both operations
that matter: 1686 us against 1023 to create, 1186 against 619 to delete. If
that were the framework's floor, the whole front-end plan of §3 would be dead --
it would be slower than the thing it replaces.

**It is not the framework.** Two readings separate them:

    warm stat, cache hot     FSKit 1.6 us   kernel 1.2 us
    cold stat, remounted     FSKit 200 us   kernel 5.2 us

The first pair says the VFS name cache absorbs repeat access completely: a
folder Finder has already looked at costs the same through FSKit as through the
kernel. Measuring only this would have been the trap -- the first run of this
test showed 1.0 us against 0.9 and looked like proof that FSKit is free. It was
proof that the cache is free.

The second pair, taken after detaching and reattaching the image, is the module
actually being asked: **~200 us per lookup that misses the cache, against 5 us
in the kernel.** That is the real framework round trip, and it is 40x. It is
also still 3.5x better than the 700 us per operation v1 pays over NFS [E, §1].

So the cost splits in two, and only one half is FSKit's:

- **A cache miss costs ~200 us.** Framework. Unavoidable. Applies to any FSKit
  module, Apple's or ours.
- **The remaining ~1500 us of a create is FAT32.** Its directory is a linear
  scan and its allocation walks a chain, and Apple's module appears to flush
  synchronously. None of that is inherited by a different filesystem.

**What this does and does not establish.** It establishes that FSKit's read and
lookup path is viable, that the cache does the heavy lifting for the browsing a
person actually does, and that the framework is not what makes Apple's msdos
module slow. It does **not** establish what an FSKit write path costs when the
filesystem behind it is fast, because FAT32 is a bad proxy for NTFS and there is
no fast FSKit filesystem on this machine to measure. That number has to be made,
not found: a module of our own over a backing store that is not the bottleneck.
Until it exists, 1686 us/file is a fact about FAT and not about the plan.


### 7. The FSKit front end: built, registered, and stopped by one switch

Done 2026-08-28 evening. `sources/LukottaFS/` is a working FSKit module --
`FSUnaryFileSystemOperations` plus `FSVolume.Operations` and
`ReadWriteOperations` over an in-memory tree -- packaged as
`LukottaFS.appex` inside the Lukotta v2 bundle.

**What worked, and it is more than §2.9 expected:**

- It **signs with `com.apple.developer.fskit.fsmodule` using nothing but the
  Developer ID Application identity, with no provisioning profile on the
  machine at all**, and `codesign --verify --strict` passes. [E]
- macOS **registers it**: `pluginkit -m -p com.apple.fskit.fsmodule` lists
  `com.lukotta.v2.fs` beside Apple's msdos, exfat and ftp modules, with its
  display name, from `/Applications/Lukotta v2.app`. [E]

So the entitlement is not the gate §2.9 worried about. Nothing had to be
requested from Apple to get this far.

**What stops it:**

    $ mount -F -t lukottafs /dev/disk6 /tmp/mnt
    Module com.lukotta.v2.fs is disabled!
    mount: Unable to invoke task

That string is in `/sbin/mount`, which reaches it through `FSModuleIdentity`.
And `FSModuleIdentity.h` is four properties long, of which the relevant one is:

    @property (nonatomic, getter=isEnabled, readonly) BOOL enabled;

**Readonly.** There is no public API to enable a module, which is what Apple's
DTS told the developer on forum thread 788609 and is now confirmed from the
header rather than from a forum post. [E]

Everything reachable without the owner was tried and none of it moves the flag:

- `pluginkit -e use -i com.lukotta.v2.fs` marks it `+` in pluginkit's own view
  and `mount` still refuses -- FSKit keeps enablement somewhere pluginkit does
  not write. [E]
- Registering from `/Applications` rather than a build directory, with
  `lsregister -f` and a fresh `pluginkit -a`: still refused. [E]
- There is no `enabledModules.plist` anywhere readable, no `com.apple.fskit`
  preference domain, and `/var/db/fskit` does not exist on this machine. The
  state is held somewhere only root or the settings UI reaches. [E]

**So the FSKit route costs exactly one user action, once per install: System
Settings > General > Login Items & Extensions > File System Extensions, and
turn Lukotta on.** Not a dialog the app can raise, not something it can do on
the person's behalf, and not something that can be done ahead of time. That is
the whole of the UX cost, and it is unavoidable on this route -- NTFSKit and
xlinuxfs both ship with the same click for the same reason.

**What this changes about the plan.** The measurement the module was built to
take -- what an FSKit create costs with a fast filesystem behind it -- cannot be
taken until that switch is flipped once. The module is built, signed,
registered and waiting; one toggle and `scripts/volume-bench.sh` against the
mount answers it in a minute.

Until then the FSKit half of §3 is blocked on a person, and the half that is not
blocked on anybody is the transport and the deletion path of the volume Lukotta
already ships. That is where the rest of the night goes.


### 8. Deletion is solved, and not by FSKit

Measured 2026-08-28, on the NTFS-over-NFS volume the application serves today,
with no extension involved:

    delete 6000 files, per-file unlink (what ships)   4028 ms
    delete 6000 files, moved to Trash (one rename)       2.9 ms
    delete 20000 files, moved to Trash (one rename)      6.3 ms
    creating .Trashes/<uid>, once per volume, ever       3.1 ms

All [E]. A thousand-fold, and the shape matters more than the number: 3.3 times
the files cost 2.2 times as much because a rename is one operation whatever is
inside the directory. A million files is the same rename. That is exactly the
requirement -- one file or a million, in about the time it takes to let go of
the mouse -- and it is reachable on the architecture that already ships.

The reason Finder cannot do this today is in §1 of nfs-stall.md: the volume has
no usable `.Trashes`, so Finder tries the rename, fails, falls back to deleting
one file at a time, and reports "some items had to be skipped". Give it the
directory and the fallback never happens.

**This reverses a decision recorded earlier in TODO.md**, where creating
`.Trashes` was "considered and rejected: it makes Finder's delete instant by
turning it into a rename, but it writes to a drive we opened, which is a thing
this application does not do." That principle is right about drive contents. It
is worth weighing against what it costs here: every native volume on macOS has
a `.Trashes`, macOS creates one itself on any external disk somebody deletes
from, and the alternative is the thing the owner describes as the worst part of
the product. One empty directory, mode 0700, made once.

**What it does not fix.** Emptying the Trash still unlinks one file at a time,
at 776 us each [E]. That is the second half, and it is answered guest-side: the
engine already runs commands in the guest, where `rm -rf` of the same 6000
files measured ~0 ms [E, TODO.md], so an emptied Trash becomes one instruction
sent over the control channel instead of 6000 round trips. Finder does not wait
on it either way.

**Sidecars, noticed while measuring.** Creating 6000 files on the NFS volume
produced 6000 `._` AppleDouble files beside them [E]. Every small-file figure
for v1 is therefore two files per file, and the create path is paying twice.
`.metadata_never_index` and the `com.apple.NFS` mount options are worth pricing
against that before any of the deeper work.


### 9. Where tonight leaves the route choice

Everything below is from measurements taken 2026-08-28/29 on this Mac and
recorded above. The summary matters because two of them point away from the
architecture §3 recommended.

**The four numbers, side by side.** Same 6000 files, same 800 MB, same SSD:

| | create | delete | write |
| --- | --- | --- | --- |
| APFS, native | 64 us | 48 us | 1667 MB/s |
| HFS+ in a disk image, kernel | 85 us | 49 us | 1316 MB/s |
| v1 NTFS over NFS on vmnet | 1110 us | 776 us | 567 MB/s |
| FAT32 through Apple's FSKit module | 1686 us | 1186 us | 949 MB/s |

**1. Deletion is no longer an argument for FSKit.** It was the strongest one:
requirement 2 of §"The target" is Finder's Trash, and a network volume was
supposed to be unable to have it. It can. `.Trashes` on the NFS volume takes
deletion from 4028 ms to 2.9 ms for 6000 files and the cost does not grow with
the count [E, §8]. That requirement is met today, on the shipping transport,
with no extension and nothing for anybody to enable.

**2. FSKit is not free, and the framework is the smaller half.** A cache miss
costs ~200 us against the kernel's 5 [E, §6]. Warm access is free, which covers
the browsing people actually do, but a first walk of a large tree pays it per
file. Whatever the write path costs is unmeasured, because FAT is a bad proxy
and the module built to answer it cannot be mounted (§7).

**3. The toggle is the real cost, and it is worse than one click.** §7 proves
the entitlement is free and registration works. What is not free is that the
owner of this machine tried to turn the module on, repeatedly, and it would not
stick -- the same failure xlinuxfs's paying customers report. Some of that was
self-inflicted (four re-registrations tonight, each issuing a new UUID and
resetting the switch), which is itself the finding: **an FSKit module's
enablement is fragile against anything that re-registers the bundle, and a
Sparkle update re-registers the bundle.** A drive that stops opening after an
ordinary update, until somebody finds a switch they were never told about, is a
worse failure than the one v2 set out to fix.

**What this changes.** Nothing about the route. v2 is the extension, and §11
records why there is no second one. What these numbers change is what has to be
true of the extension before it ships:

- **The framework is not the ceiling, but it is not free either.** 200 us on a
  cache miss against the kernel's 5 [E]. Warm access is free, which covers the
  browsing people actually do, but the first walk of a large tree pays it per
  file. A million-file copy pays it a million times.
- **The write path is still unmeasured**, because FAT is a bad proxy and the
  module built to answer it cannot be mounted. `FSPassthroughBacking` exists to
  answer exactly this: a real directory behind the module, where a create onto
  APFS costs 64 us, so whatever is measured above that is the framework's own.
  It needs the switch in §11 and nothing else.
- **Deletion is already solved** and did not need the extension [E, §8], which
  means requirement 2 is not what the extension has to earn. Requirements 1, 4
  and 5 are.

### 10. Why `vers=4` failed, and what it would take

The EINVAL in §9 is not the guest refusing NFSv4. It is the mount options.

`NfsOptions::default()` in `anylinuxfs/src/fsutil.rs` is a map, and it sets:

    vers=3  port=2049  mountport=32767  nolock  deadtimeout=45  nfc
    soft  intr  timeo=100  retrans=3

`--nfs-options vers=4` replaces the `vers` key, because it is a map. It cannot
remove the other two that matter:

- **`mountport=32767`.** NFSv4 has no mount protocol. rpc.mountd is not in the
  picture at all, and the option is meaningless to a v4 mount.
- **`nolock`.** Locking is part of the protocol in v4 rather than a sidecar
  service, so there is nothing to switch off.

Either is enough for the client to reject the mount before a packet is sent,
which is what `failed with exit code 22` is. **Nothing was learned about the
guest's v4 support, because the mount never reached it.** [E]

So the experiment is still open and it is a small one: a patch that drops
`mountport` and `nolock` when the requested version is 4, in the same place the
defaults are built. `--nfs-options` can set a key and cannot unset one, which is
why this needs a patch rather than a flag.

What it would buy, if the guest's nfsd answers v4: named attributes, and with
them somewhere for `com.apple.provenance` to live other than a `._` file beside
every file on the volume. That is the sidecar tax in §8, which is doubling every
small-file operation on the shipping path today.

What it might cost: v4 on macOS is the least-exercised path in an already
stagnant client (§2.3), and `deadtimeout`, `soft` and `intr` all behave
differently there. This is worth measuring before it is worth wanting.

Not attempted tonight: the owner asked for live testing to stop before this
could be tried, and a patch to the engine that has never been mounted is not
worth committing.



### 11. The toggle cannot be set, and v2 has no second route

The whole public FSKit surface has now been read. Enablement appears in two
places and neither can be written:

    FSModuleIdentity.enabled     readonly
    FSClient                     fetchInstalledExtensions... and nothing else

`FSClient` is one method long: it hands back the installed modules and their
`isEnabled` state. There is no counterpart that sets it. [E] With §7 --
`pluginkit -e use` moves pluginkit's own marker and not FSKit's, registering
from /Applications changes nothing, re-signing changes nothing -- the position
is settled: **an application cannot enable its own filesystem module, and cannot
ask macOS to put the question to the person either.** There is no FSKit
equivalent of `OSSystemExtensionRequest`.

**An NFS fallback was written into this document and has been taken out again.**
The idea was to try the extension and serve the drive over NFS where it is not
enabled, so that nobody is ever blocked. It is rejected, and the reason is not
subtle: a network volume cannot behave like a disk, which is the entire reason
v2 exists. Keeping one behind the extension would mean shipping the problem v2
was built to remove and calling it a safety net -- the same wedges, the same
`deadtimeout`, the same sidecar beside every file, reached by a path nobody can
see. v2 serves drives through the extension and through nothing else.

**So the switch is a hard requirement of v2, and the work is to make it cost as
little as possible.** That is a real problem with real parts, not a thing to
apologise for:

- It is once per machine, not once per drive or once per launch.
- It happens before any drive is opened, so it is not in the way of anything
  somebody is trying to do at the time.
- The failure mode when it is off is knowable in advance -- the module is
  registered and reports `isEnabled == false` through `FSClient` -- so the
  application knows before it tries, rather than after a mount fails.
- What is not yet established is whether the switch survives a Sparkle update.
  §2.9 collects reports that it does not. That is the open question that decides
  whether this route ships, and it is answered by doing it: two v2 builds, an
  update between them through the real flow, and a look at whether the module is
  still enabled afterwards. Nothing else on the list matters as much.

The owner of this machine could not make the switch hold at all on 2026-08-28.
Some of that was self-inflicted -- four re-registrations in one evening, each
issuing a new extension UUID and resetting the state underneath them -- which is
itself a finding worth keeping: **an FSKit module's enablement is fragile against
anything that re-registers the bundle.** Whatever the application does at launch
must therefore not re-register it.



### 12. The licence position of the extension, established by inspecting it

Requirement 6 asks for licence to be settled by doing rather than reading.
`otool -L` on the built `LukottaFS`, release configuration, macOS 15.4 target:

    /usr/lib/libSystem.B.dylib
    /usr/lib/libobjc.A.dylib, libsqlite3.dylib
    /usr/lib/swift/libswift*.dylib          (17 of them)
    /System/Library/Frameworks/            AppKit, CoreFoundation, CryptoKit,
                                           DiskArbitration, ExtensionFoundation,
                                           FSKit, Foundation, OSLog, Security

**Nothing outside `/usr/lib` and `/System/Library`.** [E] Not one third-party
library is linked into the extension: no Sparkle, nothing from the engine, no
vendored crate. That makes its position simpler than the application's:

- Every dependency is a macOS system library, which the GPL's system-library
  exception covers. FSKit is a system framework like Foundation.
- The extension's own source is GPL-3.0-or-later, like the rest of this
  repository, and it links nothing that constrains that.
- The engine's licences -- anylinuxfs GPL-3.0, imago MIT, krun-devices
  Apache-2.0 -- do not enter into it, because the extension does not link the
  engine. Whatever v2's backend turns out to be, if it is reached over a socket
  rather than linked, it stays out of the extension's licence surface entirely.

So the licence half of requirement 6 is settled, and it is settled in the
direction that gives the most freedom: the front end carries no obligations
beyond the ones this project already has.

The remaining halves of requirement 6 -- entitlement and signing -- were settled
in §7. **Update survival is the one that is not**, and it is the one that
decides whether the route ships. See §11.


### 13. An update takes the extension away, and the application puts it back

Measured 2026-08-28. Replacing the installed application -- which is the whole
of what an updater does -- **de-registers the filesystem extension completely**.
Not re-registered under a new identifier, as Apple forum 788609 describes: gone.

    before the replacement    pluginkit reports the module, uuid 93012EDE...
    after the replacement     pluginkit reports nothing at all
    the appex on disk         still there, 1.2 MB, signature valid            [E]

So the module is intact and macOS has simply forgotten it. What restores it,
tried in order:

    lsregister -f   on the application     does not
    lsregister -f   on the appex           does not
    pluginkit -a    on the appex           restores it                        [E]

**The application now does that at launch, and it is proven end to end.** With
the module de-registered by hand to stand in for the post-update state:

    before launch    registered = 0
    launch Lukotta v2 once
    after launch     registered = 1, com.lukotta.v2.fs(2.0.0)                 [E]

The repair runs only when the module is missing, and that condition is the whole
of the safety rather than an optimisation. Registering one that is already
registered issues a new extension UUID; doing that four times in one evening on
2026-08-28 reset the owner's System Settings switch under them each time, while
they were clicking it on. A repair that ran unconditionally at every launch
would do that to everybody, for ever.

**What is proven and what is not.** The *registration* survives an update,
because the application puts it back. Whether the *enablement* survives is still
open: the repair issues a new UUID, and if the switch is keyed to the UUID
rather than to the bundle identifier then the module comes back registered and
switched off. That cannot be measured until the switch has been on once. It is
the last unknown in requirement 6, and everything about whether this route ships
turns on it.


### 14. Every UX cost this route carries, and what was tried against each

Requirement 7. One list, nothing left implicit.

**1. The switch in System Settings. Once per machine.**
General > Login Items & Extensions > File System Extensions > Lukotta on. Until
it is on, `mount -F` answers `Module com.lukotta.v2.fs is disabled!` and the
extension serves nothing.

Tried, and none of it moves the flag [E]:

    pluginkit -e use -i com.lukotta.v2.fs   moves pluginkit's own marker only
    registering from /Applications          no change
    lsregister -f, then a fresh register    no change
    re-signing with an application-identifier and team-identifier   no change
    reading the whole public FSKit surface  FSModuleIdentity.enabled is readonly
                                            FSClient only fetches

There is no API. There is not even an equivalent of `OSSystemExtensionRequest`,
which is how a system extension gets macOS to put the question to somebody. This
cost is irreducible on this route.

**2. The switch is fragile, and the application must not be what breaks it.**
Registering a module that is already registered issues a new extension UUID. On
2026-08-28 that happened four times in one evening while the owner was clicking
the switch on, and reset it under them each time [E]. So the repair in §13 runs
only when the module is missing. That condition is not an optimisation; without
it the application would be the thing that keeps turning the switch off.

**3. An update removes the extension, and the application puts it back.**
Measured and fixed: §13. Cost to the person is nothing, provided they launch the
app once after an update, which they do by opening a drive.

**4. Still unknown: whether the switch survives that repair.** The repair issues
a new UUID. If enablement is keyed to the UUID rather than the bundle
identifier, the module comes back registered and switched off, and the person is
back at cost 1 after every update. This is the single question that decides
whether the route ships, and it cannot be measured until the switch has been on
once.

**5. Nothing else.** No password, no admin prompt, no Full Disk Access beyond
what v1 already asks, no kext, no Recovery, no reduced security. The extension
signs with a Developer ID and no provisioning profile (§7), and links nothing
outside /usr/lib and /System/Library (§12).


### 15. Kernel-offloaded I/O decides what v2 has to be

Read from `FSVolumeExtent.h` on this machine, 2026-08-28. This is the most
consequential thing found tonight and it is not a measurement, it is a type
signature.

Apple's own words at the top of that header:

> Rather than transfer file data between the module and the kernel, the module
> supplies file extent mappings to the kernel and the kernel then performs data
> transfers directly, using the same infrastructure as KEXT file systems.

That is how an FSKit module reaches kext throughput, and it is why NTFSKit
reports 572 MB/s (§2.8). Without it, every byte crosses into a user-space
process and back.

**And the signature says where the bytes have to be:**

    - (BOOL)packExtentWithResource:(FSBlockDeviceResource *)resource
                              type:(FSExtentType)type
                     logicalOffset:(off_t)logicalOffset
                    physicalOffset:(off_t)physicalOffset
                            length:(size_t)length

An extent names a **block device resource** and a **physical offset on it**. The
kernel then reads those blocks itself. So kernel-offloaded I/O is available only
when the file's data physically lives on a block device the kernel can address.

**This rules out the architecture §3 recommended.** §3 put an FSKit module in
front and a guest holding the NTFS volume behind it, reached over a socket. The
bytes in that design live inside a virtual machine. There is no block device the
host kernel can address and no physical offset to hand it, so KOIO cannot be
used, and every byte crosses the user-space boundary exactly as it does over NFS
today. A socket is a better transport than NFS, but it is the same shape, and
requirement 4 -- 80% of direct-attached -- is not reachable through it.

**What v2 has to be, if requirement 4 is real:** an FSKit module that reads NTFS
itself, on the block device, and hands the kernel extents. No virtual machine in
the data path at all. The engine's remaining job is what it is uniquely good at
and what has nothing to do with throughput.

**And that is where the hard constraint bites.** Requirement 2 says encryption
unlock must always work. On a BitLocker or LUKS volume the bytes on the device
are ciphertext: an extent handed to the kernel would be decrypted by nobody. So
encrypted volumes cannot use KOIO by construction, whatever else is built. They
have to go through the module's own read and write path, which is the slower
one.

That is not a failure, it is a split, and it should be designed for rather than
discovered later:

- **Plain NTFS** -- extents to the kernel, native throughput, requirement 4 met.
- **BitLocker and LUKS** -- the module reads and decrypts, throughput bounded by
  the user-space path, and `inhibitKernelOffloadedIO` set per item so the kernel
  never asks for a map that cannot be made. FSKit supports exactly this mix:
  "files with the inhibitKernelOffloadedIO attribute set use this protocol, and
  those without it use FSVolumeKernelOffloadedIOOperations" (FSVolume.h:854).

The volume built tonight sets `inhibitKernelOffloadedIO` on everything, which is
correct for both backings it has -- memory and a host directory are not block
devices. It is the right default, and the block-device path is what turns it off
per file.

**The cost of this, stated plainly:** v2 stops being a rewrite of the transport
and becomes an NTFS implementation. That is a much larger piece of work than §3
described, and it is the honest read of what the 80% number requires. The
alternative is to accept that v2's throughput is bounded by a user-space
crossing, which is roughly where v1 already is.


### 16. What exists tonight, and what each requirement still needs

**Built and checked, 1174 checks passing:**

| Piece | What it is |
| --- | --- |
| `LukottaFS.appex` | An FSKit module in the v2 bundle, signed with the entitlement, registered by macOS |
| Eight volume protocols | Operations, ReadWrite, Xattr, OpenClose, AccessCheck, ItemDeactivation, Rename, Preallocate |
| `FSBacking` | One seam; the volume is written once and cannot tell its backings apart |
| `FSStore` / `FSPassthrough` | Memory, and a real directory. Same 52 promises, checked against both |
| `FSBlockRange` | The block arithmetic a device-backed filesystem needs, checked without a device |
| `ExtensionRegistration` | Puts the module back after an update removes it. Proven end to end |
| `ExtensionMount` | Reads what a mount attempt came to; decides what the module claims |
| `Trash` | The `.Trashes` that turns deletion from 4028 ms into 2.9 ms |

**What each requirement still needs:**

1. **NTFS as a local volume.** Needs the switch, then an NTFS reader behind the
   seam. The seam and the protocols are done; what is missing is the filesystem
   itself.
2. **Encryption unlock.** Needs 1 first. §15 establishes it cannot use
   kernel-offloaded I/O, so it is the slower path by construction and should be
   designed that way rather than discovered.
3. **Delete like a native volume.** Solved on the shipping transport and
   measured (§8). On the extension it comes free -- a local volume gets Finder's
   Trash without anything being synthesised.
4. **80% of direct-attached.** §15 is the answer and it is uncomfortable: only
   kernel-offloaded I/O reaches it, KOIO needs the bytes on a block device the
   kernel can address, and that means v2 parses NTFS itself rather than
   proxying to a guest.
5. **Many files.** Needs the switch, then `volume-bench.sh` against the mount.
   The framework's own floor is known: 200 us on a cache miss, free when warm.
6. **Practical to ship.** Signing done, entitlement done, licence done (§12),
   update survival done for registration (§13). One thing open: whether the
   System Settings switch survives the repair, which cannot be known until it
   has been on once.
7. **UX costs written down.** Done, §14.

**The single blocking fact:** five of the seven wait on one switch that this
application cannot set, on a Mac where it would not stay on. Everything that
could be built without it has been built.


### 17. Reading NTFS directly: what is proven so far

§15 concluded that requirement 4 forces v2 to read NTFS itself rather than proxy
to a guest, because kernel-offloaded I/O needs a physical offset on a block
device. That work has started, and each layer is checked against a real volume
rather than only against fixtures we wrote.

Built, 1259 checks:

| Layer | What it does | Checked against |
| --- | --- | --- |
| `NTFSGeometry` | Cluster size, volume extent, where the MFT begins | A real 4 GB volume |
| `NTFSRecord` | A file record's header, and the fixup that makes it readable | $MFT's own record |
| `NTFSAttribute` | Walking a record's attributes without walking off it | The same record's four |
| `NTFSRunlist` | Where a file's contents are, as extents | $MFT's own DATA runlist |
| `FSBlockRange` | Which blocks a read or write touches | Arithmetic, every edge |

**The check worth naming.** The boot sector says the master file table starts at
cluster 4. Decoding $MFT's own runlist -- through geometry, record header,
fixup, attribute walk and runlist -- gives a first run beginning at cluster 4,
covering 13,088 clusters, exactly the number its attribute claims. Two
independent statements about the same fact, one read directly and one through
five layers of parsing, and they agree. [E]

**Why each layer refuses more than it accepts.** Every byte here came off a disk
somebody plugged in. The failures are not crashes, they are silent wrong
answers:

- A cluster size of zero divides by zero; a huge one allocates until the machine
  gives up.
- An MFT past the end of the volume reads the next partition along.
- A record whose sector signatures do not match was half-written; believing it
  mixes bytes from before and after a power cut.
- An attribute length of zero walks the list for ever.
- A runlist delta decoded unsigned points at the wrong end of the disk, and
  reads as a file full of somebody else's data rather than as an error.

Each of those is refused, and removing the refusal fails the suite rather than
passing quietly -- checked by removing it.

**What is still missing before a file can be read:** the filename attribute and
the directory index, which is how a name becomes a record number. Then the
volume can list and open, and `FSExtentPacker` can be handed the runs.


### 18. A real NTFS directory, listed by our own code

2026-08-28, ~22:30. The reader now goes from a raw disk image to a directory
listing with nothing borrowed: boot sector, geometry, $MFT's runlist, record 5
found by arithmetic through those runs, the root's $INDEX_ALLOCATION runs, an
INDX block read off the disk, that block's fixup, and its entries.

Listed off the 4 GB volume [E]:

    $AttrDef  $BadClus  $Bitmap  $Boot  $Extend  $LogFile  $MFT  $MFTMirr
    $Secure   $UpCase   $Volume  .      .DS_Store  .Trashes  ._.DS_Store
    ._.Trashes  ._sidecar-test  ._v4test  sidecar-test  v4test

Two things in that listing are worth noticing. `.Trashes` is the directory the
Trash fix of §8 created, seen from the other side by a completely different
reader. And the four `._` entries are the AppleDouble sidecars of §8 -- the
tax NFS pays for having nowhere to put an xattr, visible here as real files
taking real records.

**The trap this layer exists for.** The root directory of a *freshly formatted*
volume already keeps its names in `$INDEX_ALLOCATION` rather than in the record:
NTFS's own metadata files fill `$INDEX_ROOT` immediately, leaving nothing there
but the marker pointing at the first block. A reader that handles only
`$INDEX_ROOT` lists an empty root on every volume it will ever see, and reports
no error doing it. [E]

**Layers now built, 1320 checks:**

    NTFSGeometry     where things are on the volume
    NTFSRecord       a file record, and the fixup that makes it readable
    NTFSAttribute    walking a record's attributes
    NTFSRunlist      where a file's contents are, as extents
    NTFSTable        finding any record by number, through the table's own runs
    NTFSFileName     the name to show, out of the several a record carries
    NTFSIndex        the entries in a directory node
    NTFSIndexBlock   the nodes that live out on the disk
    FSBlockRange     which blocks a read or write touches

Each is checked against the real volume as well as against fixtures, and for
each the refusal that matters was removed to confirm the suite fails.

**What is still missing for requirement 1:** reading a file's contents -- which
is the runlist plus `FSBlockRange`, both built -- and then serving all of it
through `FSBacking` so the volume can answer FSKit rather than a test answering
itself. And the switch, which still gates every mount.


### 19. A file read off NTFS by our own code

2026-08-28, ~22:50. `readback.txt`, 36 bytes of known contents, written onto the
4 GB volume by the ntfs3 driver in the guest. Then found and read with no engine
and no mount in the path: [E]

    boot sector      -> NTFSGeometry
    $MFT record      -> NTFSRecord, fixup applied
    its $DATA        -> NTFSAttribute
    its runlist      -> NTFSRunlist
    record 5         -> NTFSTable, by arithmetic through those runs
    $INDEX_ALLOCATION-> NTFSRunlist again
    an INDX block    -> NTFSIndexBlock, fixup applied
    "readback.txt"   -> NTFSIndex, found by name
    its record       -> NTFSTable again
    its $DATA        -> NTFSFileData

Every byte matches what was written.

**Why this matters more than the layers did.** Everything before it proved a
parser agrees with a structure -- a real risk of circularity, since a fixture
written from the same belief as the reader agrees with it whatever that belief
is. This one is different: the bytes were put there by Microsoft's format as
implemented by Linux's ntfs3, and read by code that shares nothing with either.
The check is honest too -- a wrong expectation fails three of its assertions
rather than passing quietly, which is how a fixture-dependent check usually
rots.

**What it establishes for the architecture.** §15 concluded that requirement 4
forces v2 to read NTFS itself, because kernel-offloaded I/O needs a physical
offset on a block device and a guest cannot provide one. That conclusion implied
a great deal of work of unknown difficulty. It is now less unknown: the read path
-- geometry, records, attributes, runlists, indexes, data -- exists, is checked
against a real volume, and produced a file's contents.

**What is still missing, honestly stated:**

- **Writing.** Everything above reads. Writing NTFS means allocating clusters,
  updating the bitmap, growing runlists, and journalling to `$LogFile` so a
  power cut does not corrupt the volume. That is the larger half and none of it
  is started.
- **The B-tree properly.** Directories are listed by walking one block. Lookup
  by name should use the sort order, and large directories have subtrees this
  does not yet follow.
- **Compression, encryption, sparse edge cases, hard links, reparse points,
  `$ATTRIBUTE_LIST`** for files whose attributes do not fit one record.
- **Serving it through `FSBacking`,** so the volume answers FSKit rather than a
  check answering itself.
- **The switch**, which still gates every mount.

The honest summary is that the hardest *unknown* is now known, and the largest
*quantity* of work -- the write path -- is still ahead.


### 20. The read path is complete and waiting on the switch

2026-08-28, ~23:15. The FSKit module, handed a block device, now reads the NTFS
volume on it. Nothing is stubbed between the device and a file's contents:

    FSBlockDeviceResource -> HeldDevice -> NTFSBacking -> NTFSVolumeReader
                          -> geometry, records, attributes, runlists,
                             indexes, index blocks, file data
                          -> FSBacking -> LukottaVolume -> FSKit

The volume above did not change to accommodate any of it, which is what the seam
in §16 was for. Memory and a host directory are still behind the same interface
and still pass the same fifty-two promises.

**Proven on a real 4 GB NTFS volume, through the seam** [E]:

- the root lists, with `$MFT` and `$Volume` in it and `.` filtered out
- a name looks up and gives the record the listing gave
- a file reads back byte for byte, whole and from an offset
- `$UpCase` is 128 KB, which is true of every NTFS volume and was not read off
  this one
- every write call refuses, and the mode is 0555 so nothing has to try one

**What it cannot do, and this is not a small list:**

- **Write anything.** The larger half by far: cluster allocation, `$Bitmap`,
  growing runlists, and `$LogFile` journalling so a power cut leaves a volume
  that mounts rather than one chkdsk has to repair.
- **Follow a directory B-tree properly.** Listing walks every index block; it
  does not use the sort order to find a name, and does not descend subtrees.
- **Compression, encryption, `$ATTRIBUTE_LIST`, hard links, reparse points.**
- **Report real timestamps.** `$STANDARD_INFORMATION` is parsed as an attribute
  but its contents are not read yet, so everything shows the epoch.

**And it still cannot be mounted.** `mount -F -t lukottafs` against the real
image answers `Module com.lukotta.v2.fs is disabled!` as it has all evening.
Every requirement from 1 to 5 sits behind that one switch, and §11 establishes
there is no API to move it.

So the state is: the thing that was unknown -- whether v2 could read NTFS itself,
which §15 showed requirement 4 demands -- is now known, and demonstrated on real
bytes. The thing that is blocked is not knowledge, it is a toggle.


### 21. What the drive looks like to somebody who opens it

2026-08-28, ~23:35. The v2 backing, listing the real volume as a person would
see it: [E]

    .DS_Store  .Trashes  ._.DS_Store  ._.Trashes  ._sidecar-test
    ._v4test   readback.txt  sidecar-test  v4test

Nine entries, no NTFS internals. `$MFT`, `$Bitmap`, `$LogFile`, `$UpCase`,
`$Volume` and the rest are hidden by record number -- they are the reserved
records 0 to 15 -- and remain reachable by name, as they are on Windows. Files
carry the dates they were actually written rather than 1 January 1970.

**And the listing makes the sidecar tax visible.** Four of those nine entries
are `._` AppleDouble files: `._​.DS_Store`, `._​.Trashes`, `._sidecar-test`,
`._v4test`. Every one was created by the macOS NFS client during tonight's
measurements, because NFSv3 has nowhere to put `com.apple.provenance` (§8).
They are real files taking real records on the drive, and they would be there on
anybody's disk that had ever been mounted by v1.

That is worth stating plainly as a cost of the shipping architecture: **v1 does
not only pay for the sidecars in time, it leaves them on the drive.** A person
who opens their disk on Windows afterwards sees them. The v2 module never
creates one, because it answers xattrs itself.

**The read path, as it now stands for somebody using it:** the drive opens, the
files are the ones they put there, the names are right, the dates are right, the
metadata is hidden, and the contents come back byte for byte. What it cannot do
is accept a single write, and it cannot be mounted at all until the switch in
§11 is turned on.


### 22. What reading NTFS ourselves actually costs

2026-08-28, ~23:55. 5000 files written onto the real volume by ntfs3 in the
guest, then read by our own code with no mount, no FSKit and no engine in the
path. Release build. [E]

| | our reader | v1 over NFS | APFS native |
| --- | --- | --- | --- |
| list a directory | **28 ms / 5000 files** | 746 ms / 6000 | 51 ms / 6000 |
| look up a name | **67 us** | ~700 us per op | -- |
| read attributes | **2 us** | ~700 us per op | 1.2 us (stat) |
| read contents | **1 us** | ~700 us per op | 13.6 us (open+read) |

**Listing is 26 times faster than the shipping path and faster than APFS.**
That last comparison is not quite fair -- APFS's 51 ms was `ls -lR` through the
kernel and this is a direct call -- but the order is right, and the direction is
the one that matters: reading NTFS ourselves is not the slow part.

**This closes the question §15 opened.** §15 concluded that requirement 4 forces
v2 to read NTFS directly rather than proxy to a guest, and that implied an
unknown quantity of work at unknown cost. The cost is now measured, and the read
path is not where the difficulty is. Attributes at 2 us and contents at 1 us are
within sight of native, and they are the operations a Finder window makes
thousands of.

**Where the remaining cost lives, in order:**

1. **The framework.** ~200 us on a cache miss (§6), which is 100x the reader's
   own attribute cost. FSKit is now the expensive layer, not NTFS. That is
   worth knowing before anybody optimises the parser.
2. **Lookup, at 67 us**, because every call reads index blocks off the disk with
   nothing cached. The obvious improvement, and not urgent.
3. **Writing**, which does not exist yet and is the whole of the remaining work.

**Streaming, measured, and what it does and does not say.** 800 MB written onto
the volume by ntfs3 and read back through the runlist in 1 MB pieces, three
runs: 2562, 3347, 4663 MB/s. [E]

The spread is the useful part. All three are page-cache reads of the image file,
which lives on APFS -- a 3 GB flush between runs evicted nothing. **This does not
measure a disk.** What it measures is the reader's own overhead: decoding a
runlist, finding which extent an offset falls in, and copying. At multi-gigabyte
rates that overhead will not limit anything, which is worth knowing and is all
it establishes.

Putting 2562 MB/s beside v1's 567 MB/s would be comparing a cached read with a
real one. The number requirement 4 actually turns on is a **write to a real
device**, and there is no write path to measure.

**So what remains unmeasured is the thing that matters most**, and it is
unmeasured because it does not exist rather than because it is hard to time.


### 23. The three ways this reader could have corrupted a drive quietly

2026-08-28, ~23:05. Closed tonight, and worth listing together because they
share a shape: none of them produces an error, a log line, or anything a person
could report. The drive opens, the file opens, and what comes out is wrong.

**1. A compressed or EFS-encrypted file, served as if it were plain.** The
clusters a runlist names hold compressed or ciphered bytes. Handing them over
returns noise. To whoever opened it that is a damaged drive, not an unsupported
feature. The attribute header carries flags at 0x0C saying so; they are now read
and the file is refused. [E]

**2. A fragmented file, reported as empty.** A file with more attributes than
one record holds spills into others, and NTFS writes an `$ATTRIBUTE_LIST`
naming them. The first record may hold no `$DATA` at all. Reading that as a
zero-byte file is data loss that looks like a successful copy -- discovered
weeks later, on the other machine. The list's presence is now detected and the
file refused. [E]

**3. Slack space, served as file contents.** A file's last run is rounded up to
a cluster, so the bytes past its end are whatever was on the disk before it.
Trusting the runs rather than the size hands those over. Bounded by size, and
removing that bound fails three checks (§ commit "never read past its end"). [E]

**What refusing costs, and why it is right.** Each of these means a file that
does not open rather than one that opens wrongly. On a read-only volume that is
a visible, reportable, correct failure. The alternative is a person copying a
folder off their drive and finding out later that some of it is noise -- which is
the failure this whole project exists to prevent, arriving by a new route.

**The pattern is worth keeping** as the write path is built, where the same
class of mistake destroys the drive instead of misreading it.


### 24. The seven requirements, as they stand at midnight

| | requirement | state |
| --- | --- | --- |
| 1 | NTFS as a local volume, read and written | **read proven, write absent, mount blocked** |
| 2 | Encryption unlock still works | **not started** |
| 3 | Delete like a native volume | **solved on v1, free on v2** |
| 4 | 80% of direct-attached write | **blocked: no write path** |
| 5 | Many files without falling apart | **read proven: 5000 files, 28 ms** |
| 6 | Practical to ship | **entitlement, signing, licence, update: done** |
| 7 | Every UX cost written down | **done, §14** |

**1. Reading NTFS is done and demonstrated.** A file written by ntfs3 in the
guest is found by name through the B-tree and read back byte for byte, with no
engine and no mount in the path. Metadata files are hidden, dates are real,
compressed and encrypted files are refused rather than served as noise, and a
fragmented file is refused rather than reported empty. What is missing is every
write, and the mount, which is the switch.

**2. Encryption: the data path now exists (see §25); unlocking does not.** It is also the hard constraint. The shape is known -- §15 establishes
that an encrypted volume cannot use kernel-offloaded I/O, because the bytes on
the device are ciphertext and an extent handed to the kernel would be decrypted
by nobody -- so BitLocker and LUKS have to go through the module's own read path,
decrypting as they go. Nothing about tonight's work makes that harder; the
`ReadBytes` closure the reader is built on is exactly where a decrypting layer
belongs, and it was designed that way.

**3. Deletion.** Solved on the shipping architecture (§8) and free on this one:
a local volume gets Finder's Trash without anything being synthesised.

**4. Write throughput.** Nothing to measure, because there is no write path.
§15 says only kernel-offloaded I/O reaches native rates and §22 says the reader
is not the bottleneck -- so the shape of the answer is known and the work is not
done.

**5. Many files.** 5000 files list in 28 ms against v1's 746 ms for 6000, all
five thousand come back, none twice, all findable through the tree. The read
half is proven. The write half is not.

**6. Practical to ship.** The entitlement signs with a Developer ID and no
provisioning profile; the module registers; the licence surface is nothing
outside system libraries; an update de-registers it and the app now puts it back,
proven end to end. One thing remains unknown and only a person can answer it:
whether the System Settings switch survives that repair.

**7. UX costs.** Written down in §14, and the list did not grow tonight.

**The single sentence.** Everything that could be proven without a person
touching System Settings has been proven; the write path is the remaining work,
and it is large.


### 25. Encryption, and the claim the architecture rested on

2026-08-28, ~23:25. §24 said encryption was the one requirement nothing had
advanced, and that the `ReadBytes` closure was "exactly where a decrypting layer
belongs". That was an assertion about a design. It has now been tried.

**AES-XTS, built and checked against the IEEE 1619 vectors.** [E] Both BitLocker
and LUKS encrypt disks with it, and macOS does not expose it: CommonCrypto
documents XTS in a comment and its mode enum stops at CFB8; CryptoKit has no
block-cipher modes at all. So it is built on AES-ECB, which is what XTS is
defined over -- two ECB operations and a multiplication in GF(2^128).

Two ways to be wrong here are silent, and each is checked by breaking it:

- **The tweak is the sector number little-endian.** Reversed, sector zero
  decrypts perfectly, because zero is the same either way round, and every other
  sector returns plausible rubbish. IEEE vector 2 has a non-zero sector and
  catches it; vector 1 cannot. [E]
- **The reduction constant is 0x87.** Any other value decrypts the first block
  of each sector correctly and nothing after it. [E]

**And the whole volume, read through it.** A real NTFS volume encrypted sector
by sector, then opened, listed, and read byte for byte -- with `NTFSVolumeReader`
unchanged and unaware. The negative control holds: the same encrypted bytes do
not open as NTFS without the decrypting reader in the way. [E]

**One gap found by mutation, worth recording as method.** The first version of
that check passed with deliberately wrong widening arithmetic. XTS decrypts a
sector at a time, so a read from the middle of one must be widened to whole
sectors and trimmed back; widening by the length rather than the offset plus the
length is invisible for a short read inside one sector, which is what the volume
checks happened to do. Three straddling reads were added and the mutation then
failed. **A check that cannot fail is not a check**, and the only way to find one
is to break the thing it watches.

**What this does and does not establish.** It establishes that the architecture
accommodates encryption without disturbing anything above it, and that the data
path works. It does **not** unlock anything: getting the key -- unwrapping
BitLocker's FVEK from a recovery password, deriving LUKS's through Argon2 --
is separate work and is not started. Requirement 2 is not met. But the shape it
would take is no longer a guess, and the part that would have been hardest to
retrofit is done.


### 26. Where the night got to

23:30 on 2026-08-28. Sixty-four commits on the v2 branch, 1427 checks, lint
clean, all pushed.

**Built and proven on real bytes:**

- An FSKit module in the v2 app, signed with the entitlement, registered by
  macOS, put back automatically when an update removes it.
- A complete NTFS **read** path: geometry, records and their fixups,
  attributes, runlists, the master file table, filenames, directory B-trees and
  the blocks they spill into, file contents. Checked layer by layer against a
  real 4 GB volume, and end to end by reading back a file written by ntfs3 in
  the guest.
- **AES-XTS**, built on ECB because macOS exposes no XTS, checked against the
  IEEE 1619 vectors, and a decrypting reader that lets the whole NTFS stack read
  an encrypted volume without knowing it is encrypted.
- The measurements: 5000 files listed in 28 ms against v1's 746, attributes at
  2 us, contents at 1 us, lookup at 67 us.
- Three silent-corruption paths closed (§23) and two silent-cryptography ones
  (§25), each confirmed by breaking it and watching the checks fail.

**Not built:**

- **The write path proper.** One write exists and is verified (§28): bytes into
  clusters a file already owns. What does not exist is everything that changes
  structure: cluster allocation, `$Bitmap`, growing runlists, `$LogFile`
  journalling.
- **Unlocking.** The decryption works; getting the key does not exist.
- **The mount.** Every requirement from 1 to 5 needs the module enabled once in
  System Settings, and §11 establishes there is no API to do it.

**The honest summary.** The question §15 raised -- whether v2 can read NTFS
itself, which requirement 4 forces -- is answered yes, with numbers. The
question §11 raised -- whether the route can ship past a switch nobody can set
programmatically -- is unanswered and is not a question code can settle. And the
largest single piece of remaining work, the write path, has not started.


### 27. Three bugs found by breaking the checks, and what that says about method

Everything in §17 to §25 was written with a habit: after each piece, break the
thing the checks watch and confirm they fail. It cost a few minutes each time
and found three real defects in one hour, none of which any passing suite would
have shown.

**1. A check that could not fail.** The end-marker rule in the directory reader
-- "a marker carries no name whatever its content length says" -- had a fixture
giving the marker zero content bytes. The guard was never reached. Removing the
guard left the suite green. Without it, every folder on a volume would show a
file named after whatever bytes sat in the marker.

**2. An unsigned underflow, reachable from an ordinary volume.** Finding the
start of a free cluster run was `cluster - count + 1`. Swift evaluates left to
right, so it underflows when the run completes at cluster `count - 1` -- a
volume whose first cluster is free, asking for one cluster. On UInt64 that is a
trap, not a wrong answer. Every fixture had cluster zero in use, which is true
of any real NTFS volume, so it hid.

It surfaced only because a mutation produced **no output at all**: exit 133,
empty log. A suite that neither passes nor fails is worth chasing, and chasing
it found a bug a corrupt bitmap on somebody's drive would have hit.

**3. Eleven trapping multiplications.** That underflow prompted an audit: if one
unsigned arithmetic trap was reachable from disk contents, others would be. The
subtractions were all guarded. The multiplications were not -- eleven places
turn a cluster number into a byte offset, and a runlist can encode a
sixty-four-bit cluster. Bounded at the decoder, where the numbers are made.

**The pattern.** All three are the same shape: *the code was correct for every
input the fixtures happened to contain*. Fixtures are written by whoever wrote
the code, from the same understanding, so they agree with it. Mutation does not:
it asks whether the check would notice the code being wrong, which is a
different question from whether the code is right.

**Worth keeping for the write path**, where this class of mistake destroys a
volume rather than misreading one. A write path whose checks cannot fail is not
a tested write path, and the cost of finding that out afterwards is somebody's
drive.


### 28. The first write, verified by somebody else's driver

2026-08-28, 23:55. Thirty-two bytes written into an NTFS file by our own code,
then read back by Linux's ntfs3 driver: [E]

    LUKOTTA-V2-WROTE-THIS-AT-1048576

The volume mounts afterwards, `big.bin` is still 838,860,800 bytes, and every
other file is still there.

**Why ntfs3 is the check and our own reader is not.** Reading it back with
`NTFSVolumeReader` would prove that the reader and the writer share a belief
about where a file's bytes live. If that belief is wrong they agree with each
other and disagree with the disk, which is the failure that destroys volumes.
ntfs3 shares no code with any of this, so its agreement is evidence.

**What was written, and what was deliberately not.** Bytes into clusters the
file already owned. No cluster allocated, no `$Bitmap` bit set, no record
created, no directory index touched, nothing journalled to `$LogFile` because
there is no metadata change to undo. A power cut mid-write leaves a file with
some old bytes and some new ones, which is what a power cut leaves on any
filesystem.

Every gate was asked before a byte moved: the volume clean (§ dirty flag), the
attribute non-resident, not compressed, not encrypted, and the write inside the
file's own extents. Each of those refusals is a write that would otherwise land
on somebody else's data, and they are refusals rather than clamps -- a clamped
write stores less than was asked for and the caller cannot tell which bytes
landed.

**What this changes about requirement 4.** Not much on its own: thirty-two bytes
is not throughput. What it establishes is that the read path's model of the disk
is right in the direction where being wrong is unrecoverable. Every harder write
-- growing a file, creating one, deleting one -- is a matter of keeping several
structures in agreement, and all of them stand on knowing where a file's bytes
are. That part is now demonstrated rather than assumed.

**Still not built:** allocation, the bitmap write, record creation, index
updates, `$LogFile`. Those are the write path proper, and they remain the
largest single piece of work in v2.


### 29. Two more found the same way, and a concurrency check that was not one

2026-08-29, 00:15. §27 recorded three defects found by breaking the checks. The
method kept working.

**4. A concurrency check that passed with the lock removed.** `NTFSVolumeReader`
claimed `@unchecked Sendable` while holding a mutable cache with no lock of its
own -- safe only because `NTFSBacking` happened to take one around every call.
True by accident is not true.

A check was written: sixteen queues, all listing and asking for free space. It
passed. Under the thread sanitiser it reported no races. **And it still reported
no races with the lock deleted**, because every one of those calls went through
the backing's lock, so it exercised that and never touched the reader's. Asking
a *bare* reader the same question finds five races without the lock and none
with it. [E]

The shape is identical to §27's first defect: a check that cannot fail. It is
worth noticing that the sanitiser did not save it -- the tool was right, the
test was pointed at the wrong object.

**5. A lock that protected nothing, and state that needed one.** Auditing the
other `@unchecked Sendable` claims: `FSPassthrough` declared an `NSLock` and
never used it, which reads as protection to whoever comes next and is worse than
having none. It needs none -- every method is a POSIX call against a path,
holding nothing between calls. `LukottaFileSystem` held the mounted volume in an
unguarded `var`, and FSKit gives no promise about which queue calls
`loadResource` and `unloadResource`.

**The generalisation, now that there are five.** Every one was *correct for the
way it was being exercised* and wrong for the way it would be used. Fixtures
have cluster zero in use because real volumes do. Concurrency checks go through
the convenient entry point because that is what the other checks use. The
failures are not in the code being wrong about the domain; they are in the
checks being drawn from the same picture as the code.

Mutation is the only thing that has caught any of them, and it costs a minute
each. **It should be the habit for the write path**, where the same class of
mistake takes somebody's volume rather than misreading it.


### 30. The write path, as far as it goes

00:25 on 2026-08-29. Built and checked since §28:

| Piece | What it does | How it is checked |
| --- | --- | --- |
| `NTFSFileWrite` | Where a write lands, and every reason to refuse one | Arithmetic, and the refusals |
| `NTFSBacking.write` | The same, through the seam | Against a copy of the volume |
| `HeldDevice.write` | Down to the block device | Compiles into the shipped extension |
| `NTFSBitmap.claiming` / `releasing` | Taking and giving back clusters | Both guards removed, both fail |
| `NTFSRecord.removeFixup` | A record back into disk form | A real record, and a modified one |

**What works end to end:** thirty-two bytes into a file, verified by Linux's
ntfs3 driver reading them back, with the volume mounting and every file intact
afterwards (§28). Then the same through the seam, at a second offset, verified
the same way. [E]

**What is deliberately refused,** each because it would land on somebody else's
data: past the end of a file, into a hole, into a compressed or encrypted file,
into a small file living in its record, into a directory, onto a dirty volume,
onto a device that says it is read-only.

**What does not exist:**

- **An allocator.** `claiming` and `releasing` say whether a run of clusters may
  be taken and give back a new bitmap. Nothing chooses which run, writes the
  bitmap to the disk, or updates `$Bitmap`'s own record.
- **Growing a file.** That is allocation plus rewriting the runlist, which
  changes the record's length and may not fit, which is where
  `$ATTRIBUTE_LIST` starts.
- **Creating or deleting.** A record, a directory index entry, the B-tree
  rebalancing behind it, and the parent's timestamps -- several structures that
  must agree.
- **`$LogFile`.** Everything above changes more than one structure, and a
  failure between two of them leaves a volume chkdsk must repair. NTFS's answer
  is to journal the intent first. Nothing is journalled, so nothing above the
  in-place write is safe to do.

**The honest position on requirement 4.** A write exists and is verified, and it
is the only one that needs no journal. Everything that would make v2 a usable
read-write filesystem needs `$LogFile` first, and that is not a small piece --
it is the part that decides whether a power cut costs somebody a file or their
volume.


### 31. Everything a write needs except the one thing that makes it safe

00:35 on 2026-08-29. Since §30, three more pieces:

- **`NTFSAllocator`** chooses which clusters a file takes. One run from a hint,
  so an extended file lands beside itself; largest stretches first when it
  cannot; all of it or none, because a file half allocated leaves clusters gone
  and nothing owning them; and never more pieces than a runlist can hold. Run
  against the real volume's 795,007 free clusters in four stretches: it picks
  only free clusters, takes exactly what was asked, and refuses one more than
  exists. [E]
- **`NTFSRunlist.encode`** packs extents back into NTFS's form, checked by
  round-tripping against the decoder that is already checked against a real
  volume.
- **`NTFSRecord.removeFixup`** puts a record back into disk form, checked
  against a real record and against a modified one.

**So the parts list for "grow a file by one cluster" is now complete:** find
free space, claim it, build the new runlist, encode it, put the record back
together, write it. Every one of those exists and is checked.

**And it must not be assembled, because there is no journal.**

That sequence changes two structures -- the bitmap and the file's record -- and
they must agree. A power cut between them leaves either a cluster claimed by
nobody (a slow leak of free space, recoverable by chkdsk) or a cluster claimed
by a file that the bitmap says is free (which the next allocation hands to
somebody else, and both files are lost). NTFS's answer is `$LogFile`: write down
what is about to happen, do it, mark it done, and on the next mount finish or
undo whatever is unfinished.

Nothing here writes a log record. So the only write v2 performs is the one that
changes exactly one thing -- bytes into clusters a file already owns (§28) --
and that is deliberate rather than incidental.

**What this means for the plan.** The write path is not "mostly done". The
mechanical parts are done and the safety property is entirely absent, and the
safety property is the harder half: it is what separates a filesystem from a
program that usually works. Anybody continuing this should build `$LogFile`
before assembling the parts above, not after -- the temptation runs the other
way, because the parts are ready and a first `create` would feel like progress.

## 32. The night of 2026-08-28/29: a filesystem that makes and unmakes files

The section above ends by saying the parts were ready and should not be
assembled, because there was no journal. That was right, and the answer was not
to build `$LogFile` -- it was to notice that **no NTFS implementation outside
Microsoft has one.** ntfs-3g does not. The kernel's ntfs3 does not. v1 already
ships one of those and has always shipped it. What they do instead is say so on
the volume: set `$Volume`'s dirty flag before the first write, clear it on a
clean release, and let Windows run chkdsk if the session ends any other way.

That is the whole design, and everything below follows from it.

### The dirty flag, and what it costs

`NTFSVolumeState.setting(dirty:)` moves one bit. Only ours: Windows's own
flags -- a chkdsk it scheduled, a log update it wants -- are left exactly as
found, because clearing one tells Windows work it asked for has been done.

**`$Volume` is record 3, and `$MFTMirr` keeps copies of records 0 to 3.** So the
very first write this filesystem makes is one that has to go to two places, and
writing one copy leaves the two disagreeing -- which is exactly what chkdsk
looks for. Measured on the volume here: records 0-3 are byte-identical in both
places and record 4 is not.

The order matters and is not symmetric. Setting writes the table copy first, so
the flag is on where a mount reads it before the mirror is touched. Clearing
writes the mirror first, so the table copy is the last thing to change. Either
way, a volume that reads clean is one whose metadata agrees with itself.

A write that cannot mark the volume does not happen.

### The journal is read, never written

`NTFSJournal` reads `$LogFile`'s first page and refuses a volume with work
outstanding. Empty is safe; a restart page or a page of records is not, because
telling outstanding work from finished work needs a replay this does not do;
anything else is refused too. Reading stays allowed in all three -- a drive with
unfinished work is exactly the drive somebody wants their files off.

The volume here is 20 MB of `0xFF`: never used, because Windows has never
mounted it read-write. That is what made the earlier writes safe, and it is now
checked rather than assumed.

### Ordering, in place of atomicity

Every operation is ordered so that **every interrupted state is a leak and never
a dangling reference.** A leak is space chkdsk reclaims. A dangling reference is
a name pointing at something that is not a file.

- **create**: bitmap bit, then the record, then the name.
- **remove**: the name, then the record freed, then the bitmap bit.
- **split**: claim a cluster, write the new block while nothing points at it,
  point the parent at it -- *this is the split* -- then trim the old node. In
  the window before the trim, the names below the median are in two blocks at
  once, which no search can notice: a search below the median goes to the new
  block and never looks in the old one. Trimming first would make those names
  exist nowhere for the same length of time.
- **removing a key that has a subtree**: write the replacement first, so the
  name is in two places rather than in none.

Nothing is ever overwritten on delete. A removed file's record still carries its
name and its runlist until something else takes the slot, which is what makes
recovery possible -- and this application exists to recover things.

### Ordering names: `$UpCase`, not the language

**Swift's `uppercased()` is not how NTFS orders names, and the difference is not
academic.** Read off the volume's own `$UpCase` table:

- `ß` U+00DF: the table leaves it alone; Swift makes it `SS` -- a different
  length as well as a different value.
- `ı` U+0131: the table leaves it alone; Swift makes it `I`.

A node holding both `strasse.txt` and `straße.txt`, searched with Swift's
uppercasing, returns *the wrong file* for one of them: one file's bytes under
another file's name, with nothing reporting a fault. That was a live defect in
the read path, not a hypothetical. It is fixed, and the fix is checked by a file
of each spelling created on a volume.

The comparison was validated against the volume's own filing: every index node
of every directory, more than a thousand names, is in exactly the order this
gives. A whole-directory listing is *not* sorted and is not meant to be -- the
reader sweeps blocks as they lie rather than walking the tree.

### The B-tree

`$INDEX_ROOT` lives in the directory's record; everything else lives in `INDX`
blocks in `$INDEX_ALLOCATION`, with a `$I30` bitmap saying which blocks exist.
Three things had to be built, and two of them were got wrong first:

1. **Splitting a full leaf.** Cut by bytes rather than by count: a node of names
   of different lengths cut by count comes out lopsided, and the fuller half
   splits again on the next file. Neither half may be empty.
2. **Deepening.** `$INDEX_ROOT` cannot grow past its record. When it fills,
   everything it holds moves into a block and the root keeps one marker pointing
   there.
3. **Promoting into the right parent.** After the tree got deeper, a split still
   put its median in the root -- and a key at the wrong level cuts the whole tree
   by something that describes one leaf. **Nothing was lost: every name was in
   the listing, and a third of them could not be found by descending.** That is
   the worse failure of the two, because a listing looks right. The split now
   keeps the path down from the root.
4. **Removing a key that is not in a leaf.** A promoted key holds the tree
   together as well as naming a file. It is replaced by the largest name beneath
   it -- bigger than everything down there, smaller than everything to its right
   -- which is then removed from the leaf it came from. A subtree that removals
   have emptied has no such name; then the key simply goes and its block returns
   to the directory's bitmap.

### What it costs

Measured on a directory that has been filled and emptied, not a fresh one,
because splits, emptied nodes and reused record slots only happen the second
time round.

| | this | APFS on this machine | of native |
|---|---|---|---|
| create | 78 us | 64 us | 82% |
| remove | 60 us | 48 us | 79% |

The first honest number was 214 us, and two things fixed it. The record search
scanned the bitmap from record 24 every time, and this volume has 53,000 records
in use -- 53,000 bits per file. It now starts where the last one ended and skips
a byte of ones whole. And a create descended the directory twice, both times
through the reader's own search, which builds a Swift string for every entry of
every node it passes. One descent on raw bytes now answers both questions.

An earlier number, 1947 us, was a measurement mistake: 200 attempts' time
divided by the 14 that succeeded.

### What is proven

Thirty rounds of 400 creates and 400 removes -- 24,000 operations -- against a
copy of a real volume. Every round the directory comes back to exactly the names
it started with. Afterwards: the record bitmap and the records agree, every name
leads to a record in use, every node is in the volume's order, every name that
lists can be found by descending, no record is torn, the volume reads clean, and
Apple's own `ntfs.util` still identifies it and reads its label.

Of 130 KB changed across 4 GB, every region is accounted for by name --
`scripts/volume-diff.py` follows `$MFT`'s runlist and says which record or
cluster each one is.

### What is not there

- **Directories cannot be created.** A new directory needs an index of its own.
- **A file cannot grow.** Writes go into clusters the file already owns;
  anything else needs allocation and a runlist change in the record.
- **No rename.**
- **`$MFT` cannot grow.** When a volume's records are all in use, create
  refuses. The test volume has 411 free, which is why 400 is the batch size.
- **A full internal node does not split.** Leaves do, and the root deepens; an
  intermediate node that fills would refuse. With 4 KB blocks holding ~30 keys
  each, that is a directory of roughly 30 * 30 * 30 files before it matters, but
  it is a real limit and not a safe one to leave.
- **The System Settings switch.** Everything above runs against an image. None
  of it is reachable through FSKit until the module is enabled, and
  `FSModuleIdentity.enabled` is read-only with no programmatic equivalent.

### Method

Every check in this work was broken deliberately to see it fail. Roughly sixty
mutations tonight; about a dozen survived, and each survivor was a check that
could not fail -- a padding rule the test volume's uniform names never
exercised, a bound expressed twice so neither expression was ever the reason for
a refusal, a marker test that never reached the marker. Two survivors killed by
crashing rather than failing, which a grep for failures had been hiding.

That ratio is the argument for the method. One in five of these checks was
decoration until something broke it.

## 33. The morning of 2026-08-29: files that grow, and folders

Three more things, and the bug that hid behind two of them.

### A file can grow

A new file's bytes live inside its record; past a few hundred they go out to
clusters, and the record stops carrying the bytes and starts carrying a list of
where they are. A file crosses between those shapes exactly once. Until this,
a write past the end was refused, which meant nothing could be *put* on a
volume that was not already there -- no copying, which is most of what anybody
does with a drive.

**Three sizes, and this reader uses one of them.** `dataSize` is how long the
file is. `allocatedSize` is what its clusters come to, and chkdsk compares the
two. `initialisedSize` is how much has actually been written, and everything
past it reads as zeroes without touching the disk -- so a file with zero there
is a file **Windows reads as empty however full its clusters are**. Setting
`initialisedSize` to zero passed every check in this repository, because our own
reader hands back what is in the clusters regardless. Only reading the three out
of the attribute's own bytes catches it.

Clusters are claimed ahead of need -- doubling, capped at sixteen megabytes at a
time. That is what `allocatedSize` is *for*: a file written a megabyte at a time
otherwise pays for a bitmap search, a runlist re-encode and a record rewrite on
every megabyte. If the volume has no run that long the ask is repeated for
exactly what is needed, because refusing a write there is room for would be
worse than a fragmented file.

### Folders

A directory is a record with an index instead of contents. A new one starts with
nothing but a resident `$INDEX_ROOT`, and grows an `$INDEX_ALLOCATION` and a
`$BITMAP` the first time it outgrows its record. Both are added in the same
write that empties the root into the first block -- so a reader sees either a
directory with no blocks and a full root, or one with a block and an empty root,
never a root pointing at a block the record does not know about.

The root is emptied *before* the two attributes are added. It is what filled the
record, and they have to fit in what it gives back. Doing it the other way round
fails, and did.

### The bug that hid behind both

A node reported its free space measured from the node header. A block lays its
first entry down **after the fixup array**, twenty-four bytes further on. So a
node would say it had a hundred and twenty bytes free, a hundred-and-twenty-eight
byte entry would be judged not to fit, the split would run -- and where the entry
*did* fit by the node's reckoning but not by the block's, the block simply
refused to compose and the create failed with nothing to explain it.

Both now ask `NTFSIndexBlock.firstEntry` where entries begin. **Anything asking
how much room a node has must ask that too.** Two expressions of one layout is
the shape of most of the errors in this work.

It took an afternoon, and most of that was spent reading a stale diagnostic: a
failure reason that persisted from an earlier attempt and was reported for a
later one. And the diagnostic that eventually found it asked the volume for a
free index block -- which claims a cluster and writes the bitmap. A question that
changes what it is asked about is worse than no question.

### Where it stands

| | this | APFS here | of native |
|---|---|---|---|
| create | 74 us | 64 us | 86% |
| remove | 56 us | 48 us | 86% |
| write, 1 MB at a time | 8.6 GB/s | 14.7 GB/s bare | 58% |

The write figures are page cache on both sides. 8.6 GB/s is roughly twice the
fastest NVMe and thirty times a USB drive, which is what this is for -- on real
hardware the device decides and this does not show.

### Still not there

- **A directory cannot be removed.** Taking one away means taking its index
  apart. It is refused, not half-done.
- **No rename.**
- **`$MFT` cannot grow**, so a volume whose records are all in use refuses.
- **A full intermediate node does not split.** Leaves split and the root
  deepens; a middle node that fills would refuse. Roughly 30^3 files in one
  directory before it matters, but it is a real limit.
- **The System Settings switch**, which is everything: none of this is reachable
  through FSKit until the module is enabled, and `FSModuleIdentity.enabled` is
  read-only with no programmatic equivalent.

## 34. Auditing the wiring, which found more than building did

Everything up to here was built and mutation-tested. Then I read the FSKit
surface -- the part that connects this NTFS implementation to macOS -- line by
line and asked of each hook what it actually does. **Seven defects, all in the
shipping path, none of which any test here would ever have caught**, because
every test asked the reader and the reader agreed with the writer.

### The mount never came clean

`unloadResource` dropped the volume without releasing it. Every mount would have
left the dirty flag set: a drive Windows runs chkdsk on for nothing, and one
this filesystem then refuses to write to, because a marked volume is a volume
with work outstanding and it cannot tell its own mark from anybody else's.

Both `deactivate` and `unmount` release now, because a volume can be unmounted
without being deactivated and the two are not ordered.

### A rename destroyed what it was going to replace

Renaming over an existing file removed the target and *then* tried the rename.
If the rename could not be done -- no room in the node, a volume that turned
read-only in between -- the target is gone and the source has not moved. The
rename is tried first now, and only when it comes back refused is anything
removed.

### `truncate` was an empty function

Which is how everything overwrites a file: open it, cut it to nothing, write the
new contents. Overwriting a large file with a small one left the tail of the old
one hanging off the end of the new. The person gets a file that is part theirs
and part somebody else's.

### And fixing that exposed a leak between files

A file extended past what anybody wrote has clusters holding whatever the last
file left in them. Two things were wrong at once: growing claimed the whole file
as written, and the reader ignored the claim and served the clusters anyway. So
extending a file showed you the previous owner's bytes under your own file's
name. `initialisedSize` exists for precisely this, and both ends respect it now.

### Sizes and times in the index

`$FILE_NAME` keeps a copy of the length and the times; the directory entry keeps
a copy of that copy, and **the entry is what a listing reads**. Nothing updated
either when a file was written. Every file copied onto the volume would have
listed as zero bytes in Finder and Explorer, and reported the moment it was
created as the moment it was last modified -- exactly, nought seconds apart.

Both were invisible to every test, because every test asked the record.

### Listing a large directory was quadratic

An enumeration asks a page at a time, and every page swept every block of the
directory again: 6.4 ms and 256 reads per page for five thousand names. Fifty
pages is a third of a second, and the cost grows with the square of the
directory -- a million files, which is the case in the goal, would have taken
hours. Then, with the sweep cached, each page still copied the whole listing:
thirty milliseconds a page on a million names, the same quadratic cost one step
along.

A page is a slice now. 0.8 microseconds, whatever the size of the directory.

### The lesson

Six of these seven are the same failure: **a reader and a writer that share an
assumption agree with each other perfectly.** The tests were thorough and the
mutations were thorough, and they were all asking the same component the same
question. What found these was reading the code that faces outward and asking
what somebody else's software would see.

That is also why `scripts/volume-check.py` exists -- an independent checker,
written from the on-disk format in another language, which catches exactly this
class. It is checked against deliberate damage, because a checker that has never
failed is not a checker.

## 35. Where this stands at the end of the run, 2026-08-29 08:40

### What works, against a copy of a real NTFS volume

Files: made, filled, cut down, overwritten, renamed, moved between directories,
removed. Folders: made, filled past the point where they must acquire blocks,
emptied, removed. Directories grow -- a full leaf splits, a full root gives the
tree another level, and a key that is not in a leaf is replaced by the largest
name beneath it rather than removed.

Speed on this machine, against APFS measured the same way: 74 microseconds to
create against 64, 56 to remove against 48. Writing a megabyte at a time reaches
8.6 GB/s where the same writes with no filesystem under them reach 14.7. A
directory page costs 0.8 microseconds whatever the directory's size.

Verified three ways, deliberately not all by this code:
- 2193 checks, including thirty rounds of four hundred creates and removes.
- `scripts/volume-check.py`, written from the on-disk format in another
  language, which finds nothing wrong and is itself checked against four kinds
  of deliberate damage.
- Apple's own `ntfs.util`, which reads the volume and its label afterwards.
- The thread sanitiser, with eight queues writing at once, which finds nothing
  -- and six races the moment a lock is taken out, which is what makes the
  first statement worth anything.

### The one thing that blocks everything

`mount -F -t lukottafs` still answers **"Module com.lukotta.v2.fs is
disabled!"**. The extension is built, signed with the fskit entitlement, and
registered -- `pluginkit` lists it. What is off is the switch in System Settings
under General -> Login Items & Extensions -> File System Extensions.

There is no way to turn it on from code. `FSModuleIdentity.enabled` is
read-only, `FSClient` only reads, and there is no `OSSystemExtensionRequest`
equivalent for FSKit modules. **Re-registering does not help and actively hurts:
each new registration gives the module a new UUID and resets the switch**, which
is what happened four times in one evening and cost the owner four trips to
System Settings. So nothing here re-registers.

Everything above therefore runs against images. That is not a workaround for the
switch -- the code that mounts is the code that was tested, `NTFSBacking` behind
`LukottaVolume`, with an `FSBlockDeviceResource` in place of a file handle. But
it is not the same as having mounted, and it should not be described as though
it were.

### What is left

- **`$MFT` cannot grow.** A volume whose records are all in use refuses to
  create. Deliberately not attempted at the end of a long run: record 0 is the
  one write on the volume that destroys everything if it is wrong.
- **A full intermediate node does not split.** Leaves split and the root
  deepens; a middle node that fills would refuse.
- **Kernel-offloaded I/O is off.** The NTFS backing is on a block device and
  could offer an extent map, which is how an FSKit module reaches kernel
  throughput. The map is not built. This is the largest remaining performance
  item and the comment in the code now says so.
- **No `$EA`**, so extended attributes go to `._` files as they do on every NTFS
  volume on a Mac.
- **Preallocation changes a file's length**, where `F_PREALLOCATE` should
  reserve space without changing it. It errs long, which is visible rather than
  silent, and the flags are ignored.

### A postscript: the app does not use the extension yet

Reading for public functions the source declares and never calls -- the same
search that found `FSMountOptions.isReadOnly` parsed, tested and never asked --
turned up the whole of `ExtensionMount`. The extension is built, signed,
entitled, registered and correct. **Nothing in the application has ever asked it
to mount anything.** Every drive still opens through the v1 engine.

`ExtensionMount.attempt` now exists and is tested: it tries the extension and
falls through, shaped so that turning the switch on can never make anything
worse. A Mac too old for FSKit runs nothing; a switch that is off is
"unavailable" rather than a failure and is not logged; anything else falls back
to the engine exactly as today.

The call from `Mounter` is deliberately not made. That is the v1 path -- the
thing that must not break -- and wiring it at the end of a long run, on a
machine where a real mount cannot be tested because the switch is off, is how
somebody loses a drive. It is one call, into a function that is already checked,
and it should be made by somebody who can then plug a drive in.

**That is the honest shape of where this ends: the filesystem works and is
proven, and the two steps that connect it to a person -- the switch, and one
call in the mounter -- are both outstanding.**

### The worst one, found last: writes were the wrong shape for a disk

`HeldDevice` passed every offset and length straight to
`FSBlockDeviceResource`: one byte of a bitmap at 15324, twenty-seven bytes of a
file at 2371452928. **A file handle takes those. A block device does not** -- it
moves a whole block whichever byte was asked for, so anything smaller has to
read the block it lands in, change the part that moved, and put the whole thing
back.

So every write in this branch was proven against a file and would have failed
against a disk. And the mount is the one thing that cannot be tested here,
which is exactly why it went unnoticed: the file handle in the tests is a
faithful stand-in for everything about a device except the one property that
matters for this.

`FSBlockRange` was written for precisely this and was among the functions the
source declared and never called. That is three such finds in one morning --
`isReadOnly`, `ExtensionMount`, and this -- and the third would have made the
whole branch fail on first contact with a drive.

Reads had it too, and now do it as well. The aligned case is still one
operation and is the common one for file data; metadata costs a read, a copy and
a write, which is what it costs on every filesystem.

**Search for functions nothing calls. It found, in one morning, a mount option
that was ignored, the entire path from the app to the extension, and the reason
none of this would have worked on real hardware.**

## 36. Closing §2.6: dropping the guest, with the evidence

§2.6 asked whether the VM could go entirely and answered "not the primary",
with the note that a native NTFS backend could be added later. This section
closes that question. Everything below was verified on 2026-08-29 -- on this
machine where it says so, and against a primary source where it does not.

### What was verified

**The System Settings switch is permanent and has no API.** Enabling a module
writes `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`.
Read on this machine, it holds Apple's five (`apfs`, `exfat`, `msdos`, the
read-only `ntfs`, `ftp`) and not `com.lukotta.v2.fs`. The file is user-writable,
Apple explicitly discourages relying on it, and the setting is **per user** --
enable as user A and it reads as disabled for user B
([Apple Developer Forums 808594](https://developer.apple.com/forums/thread/808594)).
It is one click per person, once, and no route avoids it. NTFSKit's users make
the same click.

**FSKit modules must be sandboxed**
([Apple Developer Forums 808246](https://developer.apple.com/forums/thread/808246)).
Checked on the built extension: its entitlements are exactly
`com.apple.developer.fskit.fsmodule` and `com.apple.security.app-sandbox`. The
*app* is not sandboxed, and a privileged helper `com.lukotta.v2.helper` already
ships, so a key can be handed over without going through a command line.

**macFUSE 5.1 added an FSKit backend** (`-o backend=fskit`), running FUSE
filesystems entirely in user space with no kext and no Recovery-mode change
([macFUSE 5.1.0](https://macfuse.github.io/2025/10/30/macFUSE-5.1.0.html)).
macFUSE stays excluded on licence, but it is proof on shipping hardware that
FSKit can host a mature user-space driver.

**BitLocker is fully specified.** From
[libbde's format documentation](https://github.com/libyal/libbde/blob/main/documentation/BitLocker%20Drive%20Encryption%20(BDE)%20format.asciidoc):
ciphers are AES-CBC 128/256 with or without the Elephant diffuser (0x8000-0x8003)
and AES-XTS 128/256 (0x8004, 0x8005). Three FVE metadata blocks, offsets at boot
sector bytes 176, 184 and 192, signature `-FVE-FS-`. A 48-digit recovery password
-- every group divisible by 11 -- becomes a 128-bit key, then a SHA-256 loop of
**1,048,576 iterations** over (previous hash, initial hash, 16-byte salt,
counter) produces the 256-bit key. A user password is UTF-16LE, SHA-256 twice,
then the same loop. That key unwraps the VMK with **AES-CCM**; the VMK unwraps
the FVEK the same way.

**LUKS2 is fully specified.** Default `aes-xts-plain64`, 512-bit keyslot key,
Argon2id, AF stripes 4000, AF hash SHA-256.

### What that means for the crypto layer

Both formats are AES-XTS at the data layer on any volume made this decade, and
`AESXTS.swift` already passes the IEEE 1619 vectors. `DecryptingReader` already
sits between a device and a parser. **The data path is done.** What is missing is
header parsing and key derivation, and both are specified above rather than
guessed at.

Two things macOS does not provide and would have to be written: **AES-CCM** (for
the BitLocker unwrap -- CommonCrypto stops at GCM, CryptoKit has no CCM) and
**Argon2id** (for LUKS2). Both are small and both have public test vectors.

**This layer is the same in both routes below.** There is no mature, linkable,
write-capable BitLocker library to reuse: libbde's write support is marked
experimental and dislocker is shaped as a FUSE filesystem rather than a library.
So the decryption layer is ours either way -- which is fine, because it is the
part that is small and specified.

### The two routes

They differ in exactly one thing: **who parses NTFS.**

#### Route A -- our own NTFS, in Swift

```
FSBlockDeviceResource → block alignment → AES-XTS → NTFS (Swift) → FSKit → Finder
```

This is what exists today. Read and write, create, delete, rename, truncate,
folders, B-tree splits. 74 us to create a file against APFS's 64 on this Mac.

*For:* one process, no C, no interop boundary, memory-safe, no vendored
dependency to sign, notarise and track for CVEs. Measured metadata speed is
already good.

*Against:* every edge case in the wild is ours to find and fix, and we cannot
test against the variety of drives that exist. Still missing: NTFS compression
(real drives have it), `$MFT` growth, intermediate node splits, `$EA`. The
compatibility tail is unbounded and cannot be estimated honestly.

#### Route B -- libntfs-3g behind the same shell

```
FSBlockDeviceResource → block alignment → AES-XTS → libntfs-3g → FSKit → Finder
```

libntfs-3g exposes `struct ntfs_device_operations` -- a device abstraction with
caller-supplied read, write and seek. That is exactly the seam needed: hand it a
virtual device backed by the decrypting reader and it never learns what is
underneath. NTFSKit ([whereteam/ntfskit](https://github.com/whereteam/ntfskit))
already does this on this exact route.

**Licence, checked properly rather than assumed.** The first pass here said
"ntfs-3g is GPL-2.0-or-later, so linking is permitted" without reading anything.
That was right by luck, and the project contains a component for which it is
wrong.

Verified 2026-08-29 against the project's own text:

- The [README](https://github.com/tuxera/ntfs-3g/blob/edge/README) states that
  the drivers, the ntfsprogs utilities and **the shared library libntfs-3g** are
  under the GPL "either version 2 of the License, or (at your option) any later
  version". GPL-2.0-**or-later** converts to GPL-3.0 at our option, so it
  combines with this app.
- The same README states that **fuse-lite is under "the GNU LGPLv2"**, with no
  "or later". LGPL-2.0-**only** does not combine with GPL-3.0. **That component
  must not be built or linked.**
- `configure.ac` provides `--disable-ntfs-3g`, which sets `with_fuse="none"`.
  fuse-lite is then never compiled. We want the library and our own
  `ntfs_device_operations` regardless, so the FUSE driver is not wanted anyway --
  but this has to be a deliberate build flag, not an accident of packaging.
- The README is the project's statement; the file headers govern. Sampled
  `libntfs-3g/volume.c`, `libntfs-3g/attrib.c`, `libntfs-3g/device.c` and
  `include/ntfs-3g/device.h` -- the last two being exactly the ones the device
  seam uses. All four carry "either version 2 of the License, or (at your
  option) any later version".

Still to do before committing to this route: audit **every** file that ends up
in the build rather than four, and record the result in `NOTICES`. A single
GPL-2.0-only file among them would sink it, and four samples is not an audit.

Two things that do *not* change: the app is already GPL-3.0-or-later, so nothing
about its own licensing shifts; and it is distributed by Developer ID and
notarised rather than through the App Store, so the App Store terms that
conflict with the GPL do not apply.

*For:* twenty years of field testing. Compression, hibernation files, volumes
chkdsk has repaired, malformed things in the wild -- all handled. Days of
integration rather than months of implementation.

*Against:* C in a sandboxed extension, where a memory error takes the volume down
mid-copy. A vendored dependency to build, sign, notarise and watch for CVEs.
Less control over the FSKit-facing behaviour, which is where nine of last
night's defects lived.

### What is common to both, and is done

The FSKit-facing shell is the same either way, and it is the part that had the
defects: mount and unmount, the dirty-flag protocol, read-only honouring, block
alignment, the ordering rules, `ENOSPC` reporting, the paged directory listing.
`FSBacking` is a seam precisely so the thing behind it can be swapped, and
swapping it does not touch any of that.

### What neither route removes

- **The one click.** Verified above. Unavoidable.
- **The VM, for ext4, btrfs and XFS.** §2.6's finding stands: no credible
  user-space btrfs write implementation exists to port. Those keep the guest.
  The goal is the VM off the *common* path, not deleted.

### Recommendation

Route B for NTFS, ours for the crypto layer, VM retained for the Linux
filesystems. The crypto has to be written whichever route is taken and is
specified well enough to write; NTFS does not have to be, and the part that
cannot be estimated -- the compatibility tail -- is the part libntfs-3g has
already paid for.

Route A is not wasted if B is chosen: the shell, the alignment, the ordering and
the crypto all survive, and the Swift NTFS reader remains useful as an
independent check on the C one, which is exactly the kind of second opinion §33
showed this work needs.

## 37. Three blockers, not one -- and only one of them was known

§35 said the System Settings switch was "the one thing that blocks everything".
That was wrong, and it was wrong because everything in §30-§34 was proven
against a disk **image**. Images were not chosen for convenience. Verified
2026-08-29 from
[Apple Developer Forums 788609](https://developer.apple.com/forums/thread/788609),
where a DTS engineer confirms the following:

### Blocker 1 -- the switch (known)

Per user, once, no API. Documented in §36. Unavoidable on any route.

### Blocker 2 -- fskitd cannot open a physical disk

`mount -F` against a real disk fails with `NSPOSIXErrorDomain Code=13`,
Permission denied, logged as
`+[FSBlockDeviceResource(Project) openWithBSDName:writable:auditToken:replyHandler:]`
returning 13. **Disk images work. RAM disks work. Physical disks fail**,
including external USB volumes -- which is the entire use case.

Apple has acknowledged this and says fixes are awaiting OS updates. The
workaround reported in the thread is `sudo chown $(whoami) /dev/rdiskNsM` on the
device node before mounting.

**This one may be survivable here and nowhere else.** Lukotta already installs a
privileged helper (`com.lukotta.v2.helper`) and already elevates to open
physical drives -- §1 of `Mounter.mount` takes `elevated:` for exactly this
reason, because `/dev/diskNsM` is mode 640 root:operator. Handing the device
node to the user before the mount is something the helper can already do, with
no new prompt and no new click. **Untested. It is the first thing to try.**

### Blocker 3 -- Apple's NTFS kext wins the probe

> "all FSKit modules are allowed to probe anything only after all kext modules"

So macOS's own read-only NTFS driver claims an NTFS partition before any
third-party FSKit module is offered it (Apple bug
[FB18230524](https://feedbackassistant.apple.com/feedback/18230524/)). Apple
calls this architectural and allows that NTFS "may warrant special-casing".
`-t nontfs` is suggested in the thread and reported not to work.

**This kills plug-and-play auto-mount, and Lukotta does not use it.** The app is
driven by a person choosing a drive and unlocking it; v1 already unmounts what
macOS mounted and mounts its own. So the sequence is: macOS auto-mounts NTFS
read-only, Lukotta unmounts it and issues `mount -F -t lukottafs` itself. That
is what v1 does today with NFS, so the machinery exists.

It is still a real cost: a moment where the drive appears read-only before
Lukotta takes it over, and a race with anything that opens a file in between.

### What this means for the estimates in §35

The performance numbers stand -- they are arithmetic and I/O, and nothing about
them depends on where the bytes came from. **The claim that the work was "proven"
does not stand for physical drives.** Nothing in this branch has ever touched
one. Every number, every consistency check and every mutation was against an
image, and blocker 2 is the reason.

## 38. Stage-1 spike (a), run at last: FSKit's per-operation floor

§4 named this the go/no-go gate for the whole plan -- *"benchmark Apple's msdos
FSKit module... if Apple can't go fast through fskitd, neither can we"* -- and
set the fail threshold at **worse than 0.3 ms per metadata op**. It had never
been run. It needs no VM, no physical drive and no code. Run 2026-08-29.

### The controlled measurement

One FAT32 disk image, 1 GB, attached with `hdiutil`. 800 files of 512 bytes
created then deleted in one directory. **The same image mounted two ways, one
after the other, differing only in which driver serves it.**

    msdos via the kernel extension     create   207 µs    delete    53 µs   [E]
    msdos via FSKit (mount -F)         create  1363 µs    delete   743 µs   [E]

    for reference, same machine, same day:
    APFS on the internal SSD           create    55 µs    delete    30 µs   [E]
    v1, NTFS over NFS from the guest   create  1110 µs                      [E]

**FSKit costs about 1160 µs more per create and 690 µs more per delete than the
kernel path, for identical filesystem code on identical bytes.** 6.6x on create,
14x on delete.

It is not the filesystem. Per-file cost was measured at 50, 200, 800 and 2000
files in one directory and is flat (1980, 1314, 1341, 1371 µs) -- so it is not
FAT32's linear directory scan, which would grow. It is fixed per-operation
overhead in the path between the kernel and the module.

Streaming is fine: **1218 MB/s** written to the same FSKit mount. Bulk data is
not the problem; the per-operation crossing is.

### What this does to the plan

The gate in §4 fails, by a factor of 4.5. **FSKit's metadata floor on this
machine is worse than the VM-and-NFS path v2 exists to replace.** No amount of
work on the NTFS code below it changes that: 1363 µs is what it costs before
our first byte is read.

It also corrects §30-§35. Every per-operation number in those sections -- 74 µs
to create, 55 to remove, "86% of APFS" -- was measured by calling `NTFSBacking`
directly, in process, with a file handle standing in for the device. **None of
it ever crossed FSKit.** The honest projection for the same code behind a real
mount is 74 + ~1160 ≈ 1230 µs, which is v1's number, not APFS's.

Kernel-offloaded I/O does not rescue this. KOIO moves *file data* and exists
precisely because crossing is expensive; metadata operations cross regardless.

### What this does not establish

- It prices **Apple's msdos module**, which §4 nominated as the yardstick, not
  the framework floor in isolation. A module that batches or defers metadata
  might do better. Ours cannot be measured until it can mount, which is
  blocker 2 in §37.
- The FSKit mount carried `noatime` and the kext mount did not; that is a
  difference in the wrong direction (it should favour FSKit) but it is a
  difference.
- One macOS version, one machine, one day.

### The measurement that is now worth most

Whether the ~1.2 ms is fskitd's XPC round trip, or msdos's own behaviour through
it. If it is the framework, FSKit cannot meet the target on this OS and the
answer is to ship the fallback and re-test each release, exactly as §4 says. If
it is the module, a careful one might still land near 0.3 ms and the plan
survives. Blocker 2 stands in the way of settling it with our own code.

## 39. The third route, which today's measurement promotes

Dropping the VM but keeping NFS: the filesystem code runs in a process on the
Mac, holds the drive directly, and exports to `localhost`. No guest kernel, no
virtio, no gvproxy. No FSKit either, so none of §37's three blockers apply --
no switch, no `fskitd`, no kext precedence.

### What the numbers say now

§1 decomposed v1's per-operation cost and found the guest free, the kernel
transport primitives ≤40 µs, and **≥600 of the 700 µs in gvproxy plus the macOS
NFS client's RPC turnaround**, predicted split 0.3-0.5 ms gvproxy, 0.1-0.2 ms
client. Dropping the VM removes the gvproxy half and leaves the client half.

    APFS, measured                                    55-73 µs/op   [E]
    native NFS, no VM, estimated from §1's split     150-300 µs/op  [I]
    v1 today, measured                                 1110 µs/op   [E]
    FSKit, measured today (§38)                        1363 µs/op   [E]

**On metadata this route is roughly 5x better than FSKit and 4-7x better than
v1**, and it is the only one of the three whose blocking issues are all ours
rather than Apple's.

Throughput has a floor that needs no estimate: **v1 already achieves 567 MB/s
through NFS *and* a VM** [E]. Removing the VM cannot make that worse. FSKit
measured 1218 MB/s today, so FSKit likely still wins on streaming.

### What it costs, and this is the whole objection

§1's conclusion stands and is not fixed by removing the VM: *"a perfect
transport under the present design still leaves the macOS NFS client's
semantics: serial issue, network volume in Finder, no Trash, `deadtimeout`
unmounts, soft-mount short writes. Tuning cannot cross that."*

That is target 1 (a **local** volume) and target 3 (Trash and Put Back) from the
goal, and no amount of speed buys them.

### Contradictory evidence worth resolving

fuse-t uses exactly this architecture -- a userspace NFS server on loopback --
and the evidence about it points both ways. Its own documentation claims good
performance from the macOS NFSv4 client
([fuse-t.org](https://www.fuse-t.org/)), while a user pairing it with ntfs-3g
reports **20 MB/s against macFUSE's 700-800 MB/s**
([fuse-t#89](https://github.com/macos-fuse-t/fuse-t/issues/89)). One of those is
wrong or workload-specific, and v1's own 567 MB/s over NFS-plus-a-VM suggests
the 20 MB/s figure is not the general case. Worth reading before betting on it.

### How to settle it, cheaply

Serve a plain directory over NFS from macOS's own `nfsd` on loopback, mount it,
and run the same 800-file create/delete used in §38. That prices the macOS NFS
client's turnaround with no VM and no guest in the way, and it is the number the
whole route rests on. It needs `/etc/exports` and `nfsd` started, which is a
system configuration change and therefore the owner's to make, not this
process's.

### Where the three stand

| | metadata | streaming | local volume | Trash | blocked by |
| --- | --- | --- | --- | --- | --- |
| FSKit | 1363 µs [E] | 1218 MB/s [E] | yes | probably | three Apple bugs |
| native NFS, no VM | 150-300 µs [I] | ≥567 MB/s [E] | **no** | **no** | nothing |
| v1 today | 1110 µs [E] | 567 MB/s [E] | no | no | shipping |

The uncomfortable reading: **the route that meets the UX targets is the slow one,
and the route that is fast fails the UX targets.** Neither is what the goal asks
for, and that is a finding about macOS rather than about this code.
