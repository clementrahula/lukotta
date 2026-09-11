# FSKit bridge

Branch `v2-fskit`, cut from main at b14c23a (release 1.22.19 plus two fixes). FSKit replaces NFS as the host export. The microVM, cryptsetup, LVM, the image stack and the Linux filesystem drivers stay.

| Layer | Runs | Replaces |
|---|---|---|
| FSKit extension, `FSUnaryFileSystem` | macOS, user space | NFS client, AFP client |
| vsock RPC | libkrun | NFS over virtio-net |
| File server | microVM | nfsd, netatalk |
| Linux VFS and drivers: ntfs3, ext4, XFS, btrfs | microVM | nothing |
| dm-crypt, LVM, image formats | microVM | nothing |

## State on 2026-09-11

| Item | State |
|---|---|
| main (v1) | 1.22.19 released. NTFS reaches Finder over AFP (netatalk in the guest) on a hidden `nobrowse` NFS mount. |
| AFP | Stays in v1 for macOS 15–26 (owner's decision). Removed in macOS 27: v1 needs plain NFS there. |
| NFS | No deprecation found. |
| This Mac | macOS 26.6.2. The 27 APIs below need a macOS 27 RC machine. |
| Other branches | `v2-coverage`: ignored. |

## What the NFS and AFP export costs today

Measured on main, through Finder.

| Cost | Figure |
|---|---|
| Small files, NFS | 2,000 × 4 KiB in 71.4 s. AFP: 200 in 0.6 s; 20,000 in 76.1 s |
| Delete, NFS | 2,000 in 4.53 s; 10,538 in 14.1 s. AFP: 10,538 in 4.2 s |
| Trash | none: network volume, deletes in place (NFS and AFP, guest or logged in) |
| `._` files | present over NFS; none over AFP |
| `com.apple.ResourceFork` | refused over NFS with EINVAL; Finder's copy reports success and drops the fork |
| Sparse files | a sparse 1 GB file arrives fully allocated: NFSv3 carries no holes |
| readdir during a copy | host over NFS median 7.11 s, worst 90.05 s; inside the guest 0.01 s, 2.79 s |
| fsync | nfsd COMMIT fault: acknowledged data lost when the microVM is killed |
| Plumbing | hidden NFS mount + AFP mount, orphan sweeps, lowercase volume names from netatalk, "Server connections interrupted" |
| Large files, BitLocker USB stick | 7.2–9.6 MB/s; the stick's own exFAT 10.9 MB/s |
| 20 GB in 40 × 500 MB, BitLocker stick, release 1.22.19 | 48 min, 7.3 MB/s |
| Large files, NTFS image on the Mac's SSD, AFP | 1 GiB in 1.7 s, 631.6 MB/s |

## FSKit, checked here

- Apple DTS: mounting an FSKit filesystem from `FSPathURLResource` with `/sbin/mount` on macOS 26 is intended use.
- macFUSE: FSKit backend from macOS 15.4; mounts only under `/Volumes`; FSKit I/O "not on par" with the kernel extension; its FSKit channel API reads up to 15× faster with zero-copy.
- Third-party FSKit extensions were broken on 26.1 and 26.2: `fskitd` rejected unprivileged clients. Not re-tested since.
- Branch `v3-native-ntfs` (commit 7f8f0a9), macOS 26: one FAT32 image, 800 files, Apple's msdos module. Kernel extension 207 µs per create, 53 µs per delete; FSKit 1,363 µs and 743 µs. FSKit adds about 1.2 ms per metadata operation, flat from 50 to 2,000 files. Streaming 1,218 MB/s.
- Per file through Finder today: AFP 3.8 ms (20,000 in 76.1 s), NFS 35.7 ms (2,000 in 71.4 s). A Finder copy costs several metadata operations per file, so at 1.2 ms each FSKit alone lands between the two before any RPC. The prototype measures whether the 27 attribute caching closes that.

## FSKit, from the owner's research on 2026-09-11, not yet checked here

| Release | FSKit |
|---|---|
| 26 | `FSGenericURLResource`: an arbitrary URL, a network address included |
| 26.5 | LaunchServices and `fskitd` synchronisation improved |
| 27 | Handler protocols replace `FSVolume.Operations`; results carry updated attributes and free space |
| 27 | `FSContext`: caller's real and effective uid and gid |
| 27 | `FSVolume.DataCacheHandler`: none, read, write-through, write-back; push, invalidate, both. Apple: generalised leasing, meant for network filesystems |
| 27 | `SeekRegionHandler`: next data region or hole (SEEK_DATA, SEEK_HOLE) |
| 27 | `FSClient.mountSingleVolume(...)`, entitlement `com.apple.developer.fskit.mount`: load, activate, mount under `/Volumes` |
| 27 RC | 2026-09-09. Apple's Time Machine documentation: AFP not supported from 27 |

- One resource, one volume. An LVM group: one session, one URL per logical volume (`lukotta://<session>/<lv>`).
- The user enables the extension once per user: System Settings → General → Login Items & Extensions → File System Extensions. `openFileSystemExtensionsSettings()` opens the pane.
- macFUSE 5.4 (2026-09-07) uses the 27 APIs: forwards effective uid and gid, caches attributes with FUSE validity timeouts.
- No `vnode_notify` for outside changes to directories and metadata: Apple r.177724575.
- Apple does not plan a FUSE3 surface over FSKit. xlinuxfs runs Linux filesystem drivers behind FSKit through LKL.

Reported against 27 beta 5 by a developer of an SMB filesystem on FSKit, not known fixed in the RC:

- `RENAME_SWAP` reports success and destroys the destination.
- On URL-backed volumes `fsync`, `F_FULLFSYNC`, `F_BARRIERFSYNC` and `sync` succeed without `synchronize()` reaching the module.

## Prototype, on a macOS 27 RC machine

Disposable. Stop if any of the first three fails.

1. `FSGenericURLResource("lukotta://<session>/<volume>")` + `FSClient.mountSingleVolume` → `/Volumes/<label>`.
2. `fsync`, `F_FULLFSYNC`, kill-durability reach the extension and the guest: `scripts/kill-durability.sh`, `scripts/flush-reaches-drive.sh`.
3. `renameatx_np(RENAME_SWAP)` on sacrificial files.
4. `com.apple.ResourceFork`, Finder tags, quarantine, arbitrary xattrs.
5. A 1 GB sparse file through `SeekRegionHandler`: still sparse after copies both ways.
6. 6,000- and 40,000-file deletes; `scripts/readdir-under-copy.sh`.
7. Extension install, enable, update, reboot, re-register, on a clean user account.

Finder numbers against the table above: `scripts/finder-parity.sh`, `scripts/finder-copy-cycles.sh`.

## Build

- Host: the export behind a transport interface, NFS its first implementation. Wired today in `MountScript.build`, `mountCommand`, `shareServe`, the helper's mount flow and `hiddenFromFinder`, `AfpShare`, and the sweeps in `Housekeeping`.
- Transport: vsock from libkrun. Protocol: an existing Linux-VFS-shaped one (9P2000.L, or the FUSE wire format) before a new one. Server in the Alpine rootfs, added to `scripts/trim-image.py` ROOTS.
- Rollout: AFP on NFS for macOS 15–26, plain NFS on 27+. FSKit opt-in on 27+ once the fsync and `RENAME_SWAP` faults are shown fixed; the default once Finder measures it better and the one-time approval is judged acceptable; NFS removed last.
- Replaces the old choice between FSKit with our own NTFS implementation and DriverKit with a licensed driver.

## Sources

- [Apple Developer Forums 799283: FSKit with FSPathURLResource](https://developer.apple.com/forums/thread/799283)
- [Apple: FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource)
- [macFUSE wiki: FUSE backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [macFUSE releases](https://github.com/macfuse/macfuse/releases)
- [Der Flounder: AFP client deprecated in macOS 15.5](https://derflounder.wordpress.com/2025/05/14/apple-filing-protocol-client-deprecated-as-of-macos-sequoia-15-5-0/)
- [AppleInsider: Time Capsule support is dead in macOS 27](https://appleinsider.com/articles/26/06/10/time-capsule-support-is-dead-in-macos-27-but-you-can-keep-the-hardware-alive)
- [Eclectic Light: local file systems in macOS 26](https://eclecticlight.co/2025/11/18/which-local-file-systems-does-macos-26-support/)
