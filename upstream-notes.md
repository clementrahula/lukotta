<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Clement Rahula -->

# What the engine's own documentation says

Lukotta mounts through [anylinuxfs](https://github.com/nohajc/anylinuxfs). Its
README, `docs/`, and `.planning/codebase/CONCERNS.md` describe traps and limits
that this app inherits whether or not it knows about them. Read as a set, they
fall into three piles: things we already avoid, things that reach us, and
answers to problems we are still carrying.

Everything below is quoted or measured, not inferred. Where a claim is ours
rather than theirs it says so.

## Already avoided, and worth not un-avoiding by accident

**`anylinuxfs stop` kills the process group.** In `main.rs`, `stop` sends the
quit command, waits `wait_for_proc_exit` — five seconds — and then calls
`libc::killpg(session_pgid, SIGKILL)` whether or not the VM went quietly. We
measured what a killed machine costs: data the writer was told had been
committed does not survive. See `EngineProcesses.flushGrace`.

The app never calls `stop`. It ejects with
`anylinuxfs unmount <point> --wait-for-vm 30`, which takes the SIGTERM path and
gives the machine thirty seconds. Keep it that way. `EngineStatus.unmount` is
the only route that should ever end a machine that has been written to.

**Fixed ports.** 2049, 32765 and 32767 are forwarded at fixed values, so any
other NFS server on the Mac collides. Nothing to fix here; worth recognising
instantly if a mount fails on a machine that serves NFS itself.

## Reaches us

**The `ntfsfix` warning is aimed straight at our repair route.** From
`docs/important-notes.md`, on NTFS:

> using any unofficial tools like `ntfsfix` to clear dirty flag will not really
> fix those errors and can lead to further data corruption!

Clearing the dirty flag is what `MountScript.ntfsRepair` does, because the goal
says a person who asked for writable is owed writable rather than a warning.
Our guard is real — `ntfsfix -n` first, refuse if it will not vouch, and a
volume whose `$MFTMirr` did not match `$MFT` was refused with nothing written —
and 41 files came back byte-identical through a repair. But upstream's position
is stronger than ours and it is theirs to have: they consider `chkdsk` the only
real fix. Anything that widens what the repair will attempt should be weighed
against that sentence.

**We lead with ntfs3; upstream defaults to ntfs-3g on purpose.** Two documented
bugs sit behind that default:

> ntfs3 data corruption on hibernated/Fast Startup Windows drives — Mounting a
> hibernated Windows volume with `-t ntfs3` may silently corrupt data.

> Permission issues on ntfs3 Windows system drives — `/Program Files` and parts
> of `/Users` appear read-only even with write mount.

The first we guard: the repair refuses a hibernated volume, and there is a test
for it. The second is untested here and is a plain UX trap — somebody opens a
Windows system disk and finds folders they cannot write to, with nothing on
screen explaining why.

**LUKS wants far more memory than our default.**

> When you mount a LUKS-encrypted drive, the microVM requires at least 2.5 GiB
> RAM for cryptsetup to work properly.

`MountScript.ramMiB` is 512. The app sizes a LUKS machine from the volume's own
header instead of from that flat figure, which is the better answer, but the
2.5 GiB number is the one upstream will quote at a bug report.

**Multiple logical volumes in one partition cannot all be writable.**

> Multi-mount relies on file locks (to prevent data corruption) and we can only
> lock entire physical partitions. That means you can only mount multiple
> logical volumes from the same partition if you mount all of them read-only.

That is the ordinary Ubuntu and Fedora layout: LUKS holding LVM, root and home
as separate volumes in one partition. The app has no notion of this rule, so
whatever a person meets when they open the second volume, they meet it raw.

**A volume group spanning drives needs every device named**, as
`lvm:vg1:/dev/disk3s1:/dev/disk4s1:lv1`. Untested here.

**Quarantine, not permissions.** From `docs/troubleshooting.md`:

> If you get `fcopyfile failed: Operation not permitted`, it can actually mean
> the file you're trying to copy has the quarantine attribute set

A Finder copy of anything downloaded carries `com.apple.quarantine`, and NFSv3
has nowhere to put an extended attribute. This is exactly the shape of the
thing the goal forbids: an error dialog, during an ordinary copy, saying
something that is not what is wrong.

**One VM per volume, and that is fine.** Upstream: "A new virtual machine is
needed for each mounted volume... typical usage is around 256 MB per VM." We
measured twelve open at once at 1892 MB total — about 158 MB each — falling to
554 MB under memory pressure with all twelve still open and writable. The case
for patching the engine to serve several drives from one machine rested on a
figure of 493 MB per drive, which was one volume measured in the middle of a
copy. There is no memory case for that patch.

## Answers to things we are still carrying

**virtiofs, instead of NFS over loopback -- with a large caveat.** Their own
`CONCERNS.md`:

> NFS over loopback adds latency — The NFS stack (guest → gvproxy port forward
> → host NFS client) adds multiple layers of overhead for every filesystem
> operation... Improvement path: Evaluate virtiofs (`krun_add_virtiofs`) as a
> lower-latency alternative.

This is the structural answer to the whole family of faults this branch exists
for. Error 100060 is `ETIMEDOUT` from an NFS client; "the server is not
responding" is an NFS client notice; the 6-to-12 second directory listings
measured during a copy are READDIR requests queued behind writes; and a file
with a resource fork is dropped by every copy because that client refuses
`com.apple.ResourceFork` with `EINVAL` while accepting every other extended
attribute. None of those exist without an NFS client in the path, and virtiofs
carries extended attributes natively.

Three separate defects, one cause. That is the argument for removing the NFS
client from the path, and it is worth more than the sum of the tuning that has
gone into working around them.

But virtiofs is probably not the way to do it, and this was written down here
too confidently before it was checked. virtiofs is already in this stack: the
guest boots with `rootfstype=virtiofs` and the LUKS key file is handed over the
same way. That is host to guest -- it maps a directory on the Mac into the VM.

The direction needed here is the opposite. The guest mounts the drive and has
to present it back to Finder, and **macOS has no virtiofs client**. That is why
NFS is in the path at all: macOS ships an NFS client and nothing else that a VM
can serve a filesystem through without a kernel extension.

So "evaluate virtiofs" cannot mean swapping the export over. Whatever replaces
NFS has to be something macOS can mount, which means FSKit -- already the first
item in TODO.md, and blocked on third-party extensions being broken in 26.1 and
26.2 -- or a DriverKit driver, or living with NFS and tuning it.

The four symptoms and their single cause still stand. The remedy named for them
did not survive being checked. It is a large change and it is the
only one that removes the class rather than tuning it.

**ntfsprogs-plus, for repair that is actually repair.** `ntfsck` "fully check[s]
filesystem and repair[s] it", though it does not replay the journal yet. GPL-2,
so it aggregates in the guest exactly as ntfs-3g and cryptsetup already do —
nothing is linked into this app. It addresses the case our ladder currently can
only refuse: real structural damage. Alpine does not package it, so it means
building from source into the guest rather than an `apk add`.

**ntfsplus, the driver, is not for now.** Out of tree, at v2 on `ntfs-next`,
unmerged. The numbers are good — 35–110% on multithreaded writes, a 4 TB volume
mounting in under a second against ntfs3's four — and it is the write path on
disks holding the only copy of somebody's data. Revisit when it is in mainline.

## Their corrupted-image corpus

`ntfsprogs-plus/ntfs_corrupted_images` is about eighty NTFS images broken
deliberately and specifically, including a `usb_unplug_test` taken from a real
unplug. `scripts/corrupt-corpus.sh` runs the app's ladder against all of them
and checks the property that matters: a refusal must leave the image
byte-identical.

# What the other GUI over this engine has already hit

[anylinuxfs-gui](https://github.com/fenio/anylinuxfs-gui) is a Tauri app doing
the same job as this one over the same engine. Its changelog is therefore a
list of the traps a GUI over anylinuxfs falls into, written by somebody who
fell into them first. Read that way, most of it is reassuring and some of it is
not.

## Where we are already ahead

Their hardest cluster was **seeing the disk at all**. Across 0.1.8 they fixed:
Linux-only cards not detected, cards with broken GUID tables, "Linux
Filesystem" not recognised as a supported partition type, disk detection
needing native and Microsoft results merged, and a watcher that had to start
polling for physical disk changes because the events alone missed Linux-only
disks.

`DiskWatcher.ourContent` already names Microsoft Basic Data, Linux filesystem,
Linux LVM, Linux RAID, and the `Windows_NTFS` and `Linux` MBR spellings. And it
does something they do not: it *claims* those disks through the DiskArbitration
peek callback, so macOS stops offering to initialise them — an offer that sits
one click away from destroying an encrypted drive, made precisely because macOS
cannot read it.

## Where they made a choice we should not copy

0.5.1 added "extra mount options with quick-chip buttons (noatime, nodiratime,
**nobarrier**, compress-force)". `nobarrier` turns off the write barriers that
keep a journalling filesystem consistent across a crash. It is a real speed
lever and it is exactly the trade this goal refuses — and a chip button hands
the choice, and the consequence, to somebody who cannot be expected to know
what a barrier is. 0.5.0 likewise added a read-only checkbox on every disk
card. We decide read-only ourselves and say what happened.

## Numbers they settled on, against ours

- `COMMAND_TIMEOUT_SECS = 30`, `MOUNT_TIMEOUT_SECS = 60`
- mount verification raised **from 2.5 s to 10 s** in 0.1.1
- **1.5 s settle time** for a disk-list race on eject
- "Unmount before eject for safer disk removal"

Every one of those is the same shape as the timing faults measured on this
branch: a first guess at a timeout that turned out to be too short. Ours was
the half second in `EngineProcesses.stop`.

## Failures they found worth translating

`sanitize_error` in their `cli.rs` catches: not mounted, permission denied,
elevation blocked by policy, device busy, invalid argument, no space left,
read-only filesystem, and the LUKS family. Anything else falls through to the
text after `Error:`, verbatim.

Which means neither app handles the one measured here — `Failed to acquire lock
on device: file already locked`, from opening a second logical volume on a
partition that already has one open. Both would put that sentence on screen.
See `scripts/lvm-lock-rule.sh`.

Also worth having from their fixed list: 0.4.6, "Preserve ALFS_PASSPHRASE
through sudo for encrypted volume mounting". A passphrase lost across a
privilege boundary fails as a wrong passphrase, which is the most misleading
way for it to fail.
