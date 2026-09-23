# Third-Party Notices

Lukotta is licensed under the GNU General Public License, version 3 or later.
The application embeds the components listed below and redistributes them under
their respective licences. The full text of the GNU General Public License
accompanies the application.

## Corresponding Source

Lukotta is conveyed over a network. In accordance with section 6(d) of the GNU
General Public License version 3, and the corresponding provision of section 3
of version 2, the complete corresponding source for the application and for
every GPL-licensed component embedded in it is offered from the same location as
the application itself, at no additional charge.

Each release is accompanied by that source. Requests may also be addressed to
legal@lukotta.com.

## Scope of the Corresponding Source

Section 1 of version 3 of the GNU General Public License defines what the
corresponding source comprises. Two consequences of that definition are
recorded here.

**Apple's compiler and frameworks.** A Major Component, as that section defines
it, includes an essential component of the operating system on which the work
runs and the compiler used to produce the work. The System Libraries of an
executable include what is packaged with such a component and serves only to
enable use of the work with it, or to implement a Standard Interface. The
corresponding source expressly excludes System Libraries.

The Swift and Objective-C toolchains supplied with Xcode are accordingly a
Major Component, and AppKit, SwiftUI, Foundation and the other frameworks of
macOS are System Libraries. Neither is conveyed with the application, and
neither forms part of its corresponding source. Section 3 of version 2 makes
equivalent provision.

**The Linux guest.** The guest image and the application are not combined into
a single work. They execute as separate programs in separate address spaces, on
either side of a virtual machine boundary, and communicate over virtio devices
and NFS. Storing them on one medium is aggregation, and does not bring either
under the other's licence.

Components of the guest licensed under GPL-2.0-only, among them the Linux
kernel and busybox, are therefore distributed alongside an application licensed
under GPL-3.0-or-later. Nothing of either is linked into the other. Each
component is conveyed under its own licence, as listed below, and the
corresponding source for each accompanies every release.

## Conditions of Conveyance

The application is conveyed under the GNU General Public License and under no
further condition, as section 10 of version 3 requires. It is distributed
directly, signed with a Developer ID and notarised by Apple. It is not
distributed through the Mac App Store, whose terms would impose conditions on
recipients that the same section does not permit.

Signing and notarisation determine how macOS treats the binary the author
distributes. They restrict neither building, modifying nor running the work:
the build described in BUILDING.md produces a working application signed ad
hoc, without a Developer ID and without notarisation.

## Modifications to Redistributed Components

The components listed below, on the host and in the guest, are redistributed
in modified form. Each modification is recorded with its date in the table
below and in the patch that makes it, and most of the modified files also carry
that notice, as section 5(a) of the GNU General Public License version 3 and
section 4(b) of the Apache License 2.0 require. The patches are supplied under
`patches/`, netatalk's under `vendor/patches/`, and are included in the
corresponding source alongside the unmodified upstream archives to which they
apply.

SCRIBE: this paragraph is now true of all twenty-one patches and was not when
it was written -- nine carried no date anywhere, and the sentence is kept only
because each of those has since been dated in its own header. `patches/` and
`vendor/patches/` both reach the source archive now, under `anylinuxfs-patches`
and `guest-patches`; before this they did not, so the promise the last sentence
makes was one the archive did not keep. Neither fact needs saying in the
document, and both are why the wording can stand: say nothing more here unless
the checks stop guarding them.

| Component | Licence | Date | Modification |
| --- | --- | --- | --- |
| anylinuxfs | GPL-3.0-or-later | 2026-08-22 | Recognition of the VMDK, VDI, VHD and VHDX disk-image formats |
| anylinuxfs | GPL-3.0-or-later | 2026-08-25 | Separation of the image, the configuration and the logs into a directory the caller names, leaving mount points where they were |
| anylinuxfs | GPL-3.0-or-later | 2026-08-25 | Mounting of the volumes of a volume group without elevation, macOS permitting a mount on a directory its owner holds |
| anylinuxfs | GPL-3.0-or-later | 2026-08-28 | Assignment to the guest network interface of the MAC address vmnet issued |
| anylinuxfs | GPL-3.0-or-later | 2026-09-01 | A caller-supplied floor for the memory a LUKS unlock is given, read from the volume's own header, in place of a fixed 2560 MiB for every mount |
| anylinuxfs | GPL-3.0-or-later | 2026-09-02 | SCRIBE: from `patches/anylinuxfs-wait-for-the-route.patch`, a shipped modification that has never had a row here. The engine opened one connection to the machine's NFS server and read any error at all as the server having failed, including "no route to host" arriving in milliseconds because the bridge was not up yet; it now asks until the answer settles. |
| anylinuxfs | GPL-3.0-or-later | 2026-09-11 | SCRIBE: from `patches/anylinuxfs-where-the-hidden-mount-goes.patch`, also never listed. The host side of a volume is mounted under `ALFS_MOUNT_BASE` where that is set, so Finder's own mount can keep `/Volumes/<label>` and a second volume does not take it. |
| anylinuxfs | GPL-3.0-or-later | 2026-09-12 | SCRIBE: from `patches/anylinuxfs-names-are-served-as-they-are-stored.patch`, also never listed. Names are no longer composed on their way to the NFS server, so a name the volume stores decomposed resolves rather than being listed and then never found. |
| vmproxy | GPL-3.0-or-later | 2026-08-22 | Unlocking of an encrypted volume detected inside a disk image |
| vmproxy | GPL-3.0-or-later | 2026-08-28 | Announcement of the guest network interface, so that vmnet forwards to it |
| vmproxy | GPL-3.0-or-later | 2026-09-11 | SCRIBE: from `patches/vmproxy-writes-commit-at-commit.patch`, also never listed. The export is served asynchronously and the write is made durable at COMMIT rather than at every write, which is the half of the durability pair the kernel patch below completes. |
| imago | MIT | 2026-08-22 | Drivers for VDI, VHD and VHDX, the first two written as well as read; support for the sparse and stream-optimized forms of VMDK |
| imago | MIT | 2026-09-02 | Flushing of a device node with `DKIOCSYNCHRONIZECACHE`, the call a device node accepts, in place of `fsync` and `F_FULLFSYNC` |
| krun-devices | Apache-2.0 | 2026-08-22 | Selection of the VDI, VHD and VHDX drivers by disk-format number |
| krun-devices | Apache-2.0 | 2026-09-02 | Passing of the guest's flush through to a raw device, which was previously answered without being carried out |
| afpd (netatalk) | GPL-2.0-or-later | 2026-09-11 | A listing kept per folder rather than one for the whole connection, so a walk across several folders keeps each folder's place between batches and skips nothing |
| afpd (netatalk) | GPL-2.0-or-later | 2026-09-12 | Names passed to the disk as the volume stores them, `mtoupath()` no longer composing a decomposed name that was listed and then could not be resolved |
| Linux kernel | GPL-2.0-only | 2026-09-11 | An NFS COMMIT carried through to the device, so a write the client has been told is committed survives the machine dying |
| Linux kernel | GPL-2.0-only | 2026-09-11 | A directory read while it is being emptied giving every entry once and leaving none behind |
| Linux kernel | GPL-2.0-only | 2026-09-14 | Every entry on a served volume readable and writable whatever mode or flag the disk stores, a read-only snapshot still refusing |

Files added to imago by these modifications are licensed under the MIT terms of
that crate and carry a notice recording it. Lukotta's own source is not
licensed under those terms.

## Host Components

The following run on macOS, outside the Linux guest image. `vmproxy`,
`init-rootfs` and the other helper programs distributed alongside them form
part of anylinuxfs and are covered by its licence. The kernel images `Image`
and `Image-4K` are Linux kernel binaries supplied by libkrunfw.

| Component | Version | Licence | Source |
| --- | --- | --- | --- |
| anylinuxfs | 0.19.0, modified | GPL-3.0-or-later | https://github.com/nohajc/anylinuxfs |
| imago | 0.2.3, modified | MIT | https://gitlab.com/hreitz/imago |
| krun-devices | 0.1.0-1.19.3, modified | Apache-2.0 | https://github.com/containers/libkrun |
| libkrun and libkrunfw | as embedded | GPL-2.0-only AND LGPL-2.1-only | https://github.com/containers/libkrun |
| Linux kernel | 6.12.62, modified | GPL-2.0-only | https://www.kernel.org/ |
| util-linux (libblkid) | as embedded | LGPL-2.1-or-later | https://github.com/util-linux/util-linux |
| gvisor-tap-vsock (gvproxy) | as embedded | Apache-2.0 | https://github.com/containers/gvisor-tap-vsock |
| vmnet-helper | as embedded | Apache-2.0 | https://github.com/nirs/vmnet-helper |
| Sparkle | 2.9.6 | MIT AND BSD-2-Clause AND Zlib | https://github.com/sparkle-project/Sparkle |

## Linux Guest Image

The application embeds an Alpine Linux root filesystem containing the
following 81 packages. Licence identifiers are reproduced from the
package metadata contained in that filesystem. Source for each package is
available from the Alpine Linux package archive at
<https://pkgs.alpinelinux.org/> at the version stated.

| Package | Version | Licence |
| --- | --- | --- |
| acl-libs | 2.3.2-r1 | LGPL-2.1-or-later AND GPL-2.0-or-later |
| alpine-baselayout | 3.7.2-r1 | GPL-2.0-only |
| alpine-baselayout-data | 3.7.2-r1 | GPL-2.0-only |
| alpine-keys | 2.6-r0 | MIT |
| alpine-release | 3.24.1-r0 | MIT |
| apk-tools | 3.0.6-r0 | GPL-2.0-only |
| bash | 5.3.9-r1 | GPL-3.0-or-later |
| blkid | 2.42.3-r1 | LGPL-1.0-only |
| bstring | 1.1.0-r0 | BSD-3-Clause |
| btrfs-progs | 6.17.1-r1 | GPL-2.0-or-later |
| busybox | 1.37.0-r31 | GPL-2.0-only |
| busybox-binsh | 1.37.0-r31 | GPL-2.0-only |
| ca-certificates-bundle | 20260611-r0 | MPL-2.0 AND MIT |
| cryptsetup | 2.8.6-r0 | GPL-2.0-or-later WITH cryptsetup-OpenSSL-exception |
| cryptsetup-libs | 2.8.6-r0 | GPL-2.0-or-later WITH cryptsetup-OpenSSL-exception |
| db | 5.3.28-r7 | Sleepycat |
| device-mapper-event-libs | 2.03.35-r3 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| device-mapper-libs | 2.03.35-r3 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| e2fsprogs | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| e2fsprogs-libs | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| eudev-libs | 3.2.14-r6 | GPL-2.0-or-later |
| gdbm | 1.26-r0 | GPL-3.0-or-later |
| inih | 62-r0 | BSD-3-Clause |
| iniparser | 4.2.6-r0 | MIT |
| json-c | 0.18-r1 | MIT |
| keyutils-libs | 1.6.3-r4 | GPL-2.0-or-later AND LGPL-2.0-or-later |
| krb5-conf | 1.0-r2 | MIT |
| krb5-libs | 1.22.2-r1 | MIT |
| libaio | 0.3.113-r2 | LGPL-2.1-or-later |
| libapk | 3.0.6-r0 | GPL-2.0-only |
| libblkid | 2.42.3-r1 | LGPL-2.1-or-later |
| libbz2 | 1.0.8-r6 | bzip2-1.0.6 |
| libcap2 | 2.78-r0 | BSD-3-Clause OR GPL-2.0-only |
| libcom_err | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| libcrypto3 | 3.5.7-r0 | Apache-2.0 |
| libeconf | 0.8.3-r0 | MIT |
| libevent | 2.1.13-r0 | BSD-3-Clause |
| libexpat | 2.8.4-r0 | MIT |
| libffi | 3.5.2-r1 | MIT |
| libgcc | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libgcrypt | 1.12.2-r0 | LGPL-2.1-or-later AND GPL-2.0-or-later |
| libgpg-error | 1.61-r0 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libmount | 2.42.3-r1 | LGPL-2.1-or-later |
| libncursesw | 6.6_p20260516-r0 | X11 |
| libnfsidmap | 2.6.4-r6 | GPL-2.0-only |
| libpanelw | 6.6_p20260516-r0 | X11 |
| libsmartcols | 2.42.3-r1 | LGPL-2.1-or-later |
| libssl3 | 3.5.7-r0 | Apache-2.0 |
| libstdc++ | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libtirpc | 1.3.5-r1 | BSD-3-Clause |
| libtirpc-conf | 1.3.5-r1 | BSD-3-Clause |
| libuuid | 2.42.3-r1 | BSD-3-Clause |
| libverto | 0.3.2-r2 | MIT |
| lsblk | 2.42.3-r1 | GPL-2.0-or-later |
| lvm2 | 2.03.35-r2 | GPL-2.0-or-later AND LGPL-2.1-or-later AND BSD-2-Clause |
| lvm2-libs | 2.03.35-r2 | GPL-2.0-or-later AND LGPL-2.1-or-later AND BSD-2-Clause |
| lzo | 2.10-r5 | GPL-2.0-or-later |
| mariadb-connector-c | 3.4.6-r0 | LGPL-2.1-or-later |
| mdadm | 4.3-r3 | GPL-2.0-only |
| mount | 2.42.3-r1 | GPL-3.0-or-later AND GPL-2.0-or-later AND GPL-2.0-only AND GPL-1.0-only AND LGPL-2.1-or-later AND BSD-1-Clause AND BSD-3-Clause AND BSD-4-Clause-UC AND MIT AND Public-Domain |
| mpdecimal | 4.0.1-r0 | BSD-2-Clause |
| musl | 1.2.6-r2 | MIT |
| musl-utils | 1.2.6-r2 | MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| ncurses-terminfo-base | 6.6_p20260516-r0 | X11 |
| netatalk | 4.5.0-r0 | GPL-2.0-or-later |
| nfs-utils | 2.6.4-r6 | GPL-2.0-only |
| ntfs-3g | 2026.2.25-r0 | GPL-2.0-only |
| ntfs-3g-libs | 2026.2.25-r0 | GPL-2.0-only |
| ntfs-3g-progs | 2026.2.25-r0 | GPL-2.0-only |
| popt | 1.19-r4 | MIT |
| python3 | 3.14.7-r1 | PSF-2.0 |
| readline | 8.3.3-r1 | GPL-3.0-or-later |
| rpcbind | 1.2.9-r0 | BSD-3-Clause |
| scanelf | 1.3.9-r1 | GPL-2.0-only |
| sqlite-libs | 3.53.4-r0 | blessing |
| talloc | 2.4.4-r1 | LGPL-3.0-or-later |
| userspace-rcu | 0.15.3-r0 | LGPL-2.1-or-later |
| xfsprogs | 7.0.1-r0 | LGPL-2.1-or-later |
| xz-libs | 5.8.3-r0 | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later |
| zlib | 1.3.2-r0 | Zlib |
| zstd-libs | 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later |

The guest image is a reduced subset of Alpine Linux, containing only the
packages required to unlock and mount the supported filesystems. It contains
no ZFS components: neither the `zfs` and `zfs-libs` packages nor the `zfs.ko`
and `spl.ko` kernel modules are distributed with Lukotta.

The kernel modules are removed by path rather than by package, because no
package owns them: `zfs.ko` and `spl.ko` are part of the base image's module
tree, so dropping the `zfs` and `zfs-libs` packages removes the userspace and
leaves the modules behind. `scripts/trim-image.py` removes `lib/modules/*/fs/zfs`
explicitly, and the packed archive is checked to contain neither.

The table above is the image's Alpine package list and nothing else, rendered
from the inventory the audit scans, so a program this project compiles itself
and places inside the guest is listed here instead. `ntfsck` is such a program:
Alpine packages no NTFS checker, `scripts/build-ntfsck.sh` builds one from
ntfsprogs-plus for the guest's architecture and libc, and
`scripts/vendor-engine.sh` installs it at `/usr/sbin/ntfsck`. It is
redistributed unmodified, at the revision named below, and its source
accompanies the release as every other component's does. An application built
without that step carries no checker.

SCRIBE: correct the rule in the paragraph above, which as written covers `afpd`
and is wrong about it. `afpd` is compiled by this project and placed inside the
guest too, and it is not listed here: it is Alpine's own `netatalk` package,
built from the same version with two patches, so it is in the table above as a
package and in the Modifications table as a modification. What belongs here is
narrower -- a component Alpine does not package at all, which is why nothing
named it and, until this change, nothing fetched its source either.

SCRIBE: also correct the licence in the row below if it reads as one identifier.
The binary is linked static, so what ships is the whole library as well as the
utility: of the 57 source files in the pinned revision, 54 are GPL-2.0-or-later
and three -- `src/ntfsck.c`, `libntfs/fsck.c` and `libntfs/problem.c` -- carry
`SPDX-License-Identifier: GPL-2.0`. Notes on the Listings says a component under
more than one licence keeps the full expression, so it does.

| Component | Version | Licence | Source |
| --- | --- | --- | --- |
| ntfsprogs-plus (ntfsck) | revision 3fe890434082973aa98fd441d65ae84e5d6e5fc8 | GPL-2.0-only AND GPL-2.0-or-later | https://github.com/ntfsprogs-plus/ntfsprogs-plus |

## Notes on the Listings

- Licence identifiers are reproduced verbatim from each package's own
  metadata. Packages under more than one licence retain the full expression
  rather than being reduced to a single identifier.
- `blessing` is the SPDX identifier for the SQLite licence, under which the
  work is dedicated to the public domain.
- `cryptsetup` is distributed under GPL-2.0-or-later with an OpenSSL
  exception, as recorded in its licence expression.
- The full licence text of each component accompanies it within the guest
  image and within the corresponding source archive.


## Trademarks

Lukotta, the Lukotta wordmark and the Lukotta logo are trademarks of Clement
Rahula and are not licensed under the GPL, as section 7(e) of that licence
allows. The code may be forked and redistributed freely; a modified version
must carry its own name and artwork. See TRADEMARKS.txt in the source.

BitLocker and Windows are trademarks of Microsoft Corporation. Linux is a
registered trademark of Linus Torvalds. macOS, Finder and Apple Silicon are
trademarks of Apple Inc. Lukotta is not affiliated with, endorsed by, or
sponsored by any of them, and names them to state what it works with.
