# FSKit adapter

Goal: replace the NFS export with an FSKit volume. Linux drivers stay; no filesystem is written here.

## Decision

| macOS | Route |
| --- | --- |
| 15–26 | Existing: microVM, NFS, AFP for writable NTFS. Unchanged |
| 27+ | FSKit adapter |

One app. The route is chosen at run time; the deployment target stays macOS 15.

## Why

Measured 2026-09-16, macOS 27.0, SANDISK stick, Finder via `scripts/finder-parity.sh`:

| Transport | 1 GB copy | 2,000 × 4 KB | Delete 2,000 | `._` left |
| --- | --- | --- | --- | --- |
| NFS (macOS 27 today) | 40.1 / 43.3 MB/s | 26.2 / 28.5 s | 5.07 / 3.80 s | yes |
| SMB from the guest (`archive/smb-on-27`) | 55.6–58.7 MB/s | 45.4–63.7 s | 3.52–8.31 s | yes |
| AFP (macOS 26, 2026-09-12, fill state unrecorded) | 71.1 MB/s | 4.8 s | 1.30 s | no |

Also on NFS: no Trash, no holes (NFSv3), readdir stalls during a copy (median 7.11 s), network-volume icon, `._` sidecar files.

FSKit cost on this Mac, Apple's exFAT module, 5,000 files on an SSD image: 0.21 ms per create, 0.18 ms per delete. NFS above: 13–14 ms per file.

## Routes

| Route | Linux drivers run in | Encryption, LVM, images | Work | Status elsewhere |
| --- | --- | --- | --- | --- |
| A. FSKit extension → microVM file server | the existing microVM | unchanged | extension + transport + guest server | none shipping |
| B. FSKit extension with LKL in-process | the extension (Linux Kernel Library) | must move in-process: cryptsetup, LVM, imago | large; no VM | xlinuxfs (ext4/XFS/Btrfs RW), xntfs (ntfs-3g); App Store, closed source |
| C. macFUSE FSKit backend | either | either | small | needs macFUSE installed: rejected |

### Route A: guest protocol

| Protocol | Guest side | Extension side | Holes | xattrs | fsync |
| --- | --- | --- | --- | --- | --- |
| A1. NFS | existing nfsd | libnfs (LGPL-2.1, v3/v4, async, READDIRPLUS) | no (v3) | v4.2 only | COMMIT fault known |
| A2. 9P2000.L | diod or similar, added to rootfs | own client | no | yes | yes |
| A3. FUSE wire format | own server on the mounted tree | own client | yes | yes | yes |
| A4. Own RPC on vmproxy's vsock gRPC | agent in vmproxy | own client | yes | yes | yes |

Transport: libkrun maps guest vsock ports to Unix sockets on the host. The extension is sandboxed: socket in an app group container.

## FSKit on macOS 27: what is new

From the macOS 27.0 SDK headers on this Mac (`FSKIT_API_AVAILABILITY_V3`). Earlier work in the archives used the macOS 26 API.

| API | What it gives |
| --- | --- |
| `FSVolume.Handler` and result classes | Results carry item attributes; FSKit caches every attribute returned. Replaces `FSVolume.Operations` |
| `FSVolume.DataCacheHandler` | Kernel data caching per open file: read cache, write-through, write-back; deferred close; lease-break actions (push dirty, invalidate) |
| `FSVolume.ReadWriteHandler` | Data I/O through the module |
| `FSVolume.KernelOffloadedIOHandler` | Kernel does I/O on block extents; read-only extent type new. Block-device volumes only |
| `FSVolume.SeekRegionHandler` | `SEEK_DATA`/`SEEK_HOLE`: sparse files |
| `FSVolume.XattrHandler` | Extended attributes |
| `FSVolume.RenameHandler`, `PreallocateHandler`, `AccessCheckHandler`, `OpenCloseHandler`, `ItemDeactivationHandler` | Handler forms of the same operations |
| `FSContext` | Caller real and effective uid/gid |
| `FSFreeSpace` | Free space with sequence numbers |
| `FSItem.tryReclaim` | Item reclaim control |
| `FSClient.mountSingleVolume` | Load, activate, mount under `/Volumes`; `com.apple.developer.fskit.mount` |
| `FSClient.openFileSystemExtensionsSettings` | Opens the enable pane. `FSModuleIdentity.isEnabled` stays read-only |

For route A: the data cache and cached attributes keep repeat reads, stats and listings in the kernel, off the vsock round trip; seek-region and xattr handlers cover holes and `._` files.

## FSKit on macOS 27, constraints

| Item | Fact |
| --- | --- |
| Enable | Per user, System Settings → Login Items & Extensions → File System Extensions. No API. `FSClient.openFileSystemExtensionsSettings()` opens the pane |
| Mount | `FSClient.mountSingleVolume` with `com.apple.developer.fskit.mount`; `FSGenericURLResource` for a non-device backend |
| Shape | One resource, one volume. LVM: one URL per logical volume |
| Update | App update de-registered the appex on macOS 26 (`archive/v3-fskit`, architecture_v2.md §13); `pluginkit -a` restores. Not checked on 27 |
| Update while mounted | Force-unmount (FB21287341) |
| Reported on 27 beta 5, SMB-on-FSKit developer | `RENAME_SWAP` destroys destination; `fsync`/`F_FULLFSYNC` on URL volumes never reach the module |
| Outside changes | No `vnode_notify` (r.177724575) |
| Finder | FSKit volume is local: Locations, Trash |
| Apple DTS, Aug 2026 | FSKit "not really there yet" for network filesystems |

## Salvage from archives

| Tag | Path | Use |
| --- | --- | --- |
| `archive/v3-fskit` | `sources/LukottaFS/FileSystem.swift`, `Volume.swift` | `FSUnaryFileSystem` skeleton; macOS 26 `Operations` protocols, port to 27 handlers |
| `archive/v3-fskit` | `sources/LukottaCore/ExtensionRegistration.swift`, `ExtensionMount.swift` | registration, re-register after update, mount |
| `archive/v3-fskit` | `sources/LukottaCore/FSBacking.swift`, `FSPassthrough*.swift` | backing interface; passthrough for measuring FSKit alone |
| `archive/v3-fskit` | `build-app.sh` appex wiring | `Contents/Extensions/LukottaFS.appex` |
| `archive/v2-fskit` | `FSKIT-BRIDGE.md` | route A plan, costs, prototype list |
| `archive/v3-native-ntfs` | own NTFS driver | not used |

## Plan

Stop at the first failing step.

1. Port the `LukottaFS` skeleton to the macOS 27 handler protocols, behind `#available(macOS 27, *)`. Mount a `FSGenericURLResource` with `mountSingleVolume` over a passthrough directory. Record: enable path, re-registration after an update.
2. Passthrough baseline: `finder-parity.sh` on the FSKit volume against the same directory natively, with and without `DataCacheHandler` write-back.
3. Transport: request round trip, extension ↔ guest over the libkrun vsock socket.
4. A1: libnfs in the extension against the existing guest nfsd, SANDISK. Finder numbers against the table above.
5. Faults: `RENAME_SWAP`, `fsync` reaching the drive (`scripts/flush-reaches-drive.sh`, `scripts/kill-durability.sh`), `._` files, holes, 6,000- and 40,000-file deletes, readdir during a copy.
6. Choose A1, or A3/A4 where A1 fails step 5. Route B only if route A cannot reach AFP's numbers.

## Sources

- [FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource)
- [Forums 799283: FSKit with FSPathURLResource](https://developer.apple.com/forums/thread/799283)
- [Forums 808246: FSKit sandbox restrictions](https://developer.apple.com/forums/thread/808246)
- [Forums 842736: FSKit and network filesystems](https://developer.apple.com/forums/thread/842736)
- [Forums 809747: update while mounted](https://developer.apple.com/forums/thread/809747)
- [macFUSE 5.4.0](https://macfuse.github.io/2026/09/07/macfuse-5.4.0.html)
- [macFUSE: FUSE backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [xntfs and xlinuxfs](https://www.v2ex.com/t/1225846)
- [libnfs](https://github.com/sahlberg/libnfs)
- [LKL](https://github.com/lkl/linux)
