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

**virtiofs, instead of NFS over loopback.** Their own `CONCERNS.md`:

> NFS over loopback adds latency — The NFS stack (guest → gvproxy port forward
> → host NFS client) adds multiple layers of overhead for every filesystem
> operation... Improvement path: Evaluate virtiofs (`krun_add_virtiofs`) as a
> lower-latency alternative.

This is the structural answer to the whole family of faults this branch exists
for. Error 100060 is `ETIMEDOUT` from an NFS client; "the server is not
responding" is an NFS client notice; the 6-to-12 second directory listings
measured during a copy are READDIR requests queued behind writes. None of those
exist without an NFS client in the path. It is a large change and it is the
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
