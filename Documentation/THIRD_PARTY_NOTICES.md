# Third-Party Notices

Lukotta is licensed under the GNU General Public License, version 3 or
later. The application embeds the components listed below and redistributes
them under their respective licences. The full text of the GNU General Public
License accompanies the application.

## Corresponding Source

Lukotta is conveyed over a network. In accordance with section 6(d) of the
GNU General Public License version 3, and the corresponding provision of
section 3 of version 2, the complete corresponding source for the
application and for every GPL-licensed component embedded in it is offered
from the same location as the application itself, at no additional charge.

Each release is accompanied by that source. Requests may also be addressed
to lukotta@rahula.dev.

## Host Components

The following run on macOS, outside the Linux guest image. `vmproxy`,
`init-rootfs` and the other helper programs distributed alongside them form
part of anylinuxfs and are covered by its licence. The kernel images `Image`
and `Image-4K` are Linux kernel binaries supplied by libkrunfw.

| Component | Version | Licence | Source |
| --- | --- | --- | --- |
| anylinuxfs | 0.19.0 | GPL-3.0-or-later | https://github.com/nohajc/anylinuxfs |
| libkrun and libkrunfw | as embedded | GPL-2.0-only AND LGPL-2.1-only | https://github.com/containers/libkrun |
| Linux kernel | 6.12.62 | GPL-2.0-only | https://www.kernel.org/ |
| util-linux (libblkid) | as embedded | LGPL-2.1-or-later | https://github.com/util-linux/util-linux |
| gvisor-tap-vsock (gvproxy) | as embedded | Apache-2.0 | https://github.com/containers/gvisor-tap-vsock |
| vmnet-helper | as embedded | Apache-2.0 | https://github.com/nirs/vmnet-helper |
| Sparkle | 2.9.6 | MIT AND BSD-2-Clause AND Zlib | https://github.com/sparkle-project/Sparkle |

## Linux Guest Image

The application embeds an Alpine Linux root filesystem containing the
following 66 packages. Licence identifiers are reproduced from the
package metadata contained in that filesystem. Source for each package is
available from the Alpine Linux package archive at
<https://pkgs.alpinelinux.org/> at the version stated.

| Package | Version | Licence |
| --- | --- | --- |
| alpine-baselayout | 3.7.2-r1 | GPL-2.0-only |
| alpine-baselayout-data | 3.7.2-r1 | GPL-2.0-only |
| alpine-keys | 2.6-r0 | MIT |
| alpine-release | 3.24.1-r0 | MIT |
| apk-tools | 3.0.6-r0 | GPL-2.0-only |
| bash | 5.3.9-r1 | GPL-3.0-or-later |
| blkid | 2.42.1-r0 | LGPL-1.0-only |
| btrfs-progs | 6.17.1-r1 | GPL-2.0-or-later |
| busybox | 1.37.0-r31 | GPL-2.0-only |
| busybox-binsh | 1.37.0-r31 | GPL-2.0-only |
| ca-certificates-bundle | 20260611-r0 | MPL-2.0 AND MIT |
| cryptsetup | 2.8.6-r0 | GPL-2.0-or-later WITH cryptsetup-OpenSSL-exception |
| cryptsetup-libs | 2.8.6-r0 | GPL-2.0-or-later WITH cryptsetup-OpenSSL-exception |
| device-mapper-event-libs | 2.03.35-r3 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| device-mapper-libs | 2.03.35-r3 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| eudev-libs | 3.2.14-r6 | GPL-2.0-or-later |
| gdbm | 1.26-r0 | GPL-3.0-or-later |
| json-c | 0.18-r1 | MIT |
| keyutils-libs | 1.6.3-r4 | GPL-2.0-or-later AND LGPL-2.0-or-later |
| krb5-conf | 1.0-r2 | MIT |
| krb5-libs | 1.22.2-r1 | MIT |
| libaio | 0.3.113-r2 | LGPL-2.1-or-later |
| libapk | 3.0.6-r0 | GPL-2.0-only |
| libblkid | 2.42.1-r0 | LGPL-2.1-or-later |
| libbz2 | 1.0.8-r6 | bzip2-1.0.6 |
| libcap2 | 2.78-r0 | BSD-3-Clause OR GPL-2.0-only |
| libcom_err | 1.47.4-r0 | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT |
| libcrypto3 | 3.5.7-r0 | Apache-2.0 |
| libeconf | 0.8.3-r0 | MIT |
| libevent | 2.1.13-r0 | BSD-3-Clause |
| libexpat | 2.8.2-r0 | MIT |
| libffi | 3.5.2-r1 | MIT |
| libgcc | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libmount | 2.42.1-r0 | LGPL-2.1-or-later |
| libncursesw | 6.6_p20260516-r0 | X11 |
| libnfsidmap | 2.6.4-r6 | GPL-2.0-only |
| libpanelw | 6.6_p20260516-r0 | X11 |
| libsmartcols | 2.42.1-r0 | LGPL-2.1-or-later |
| libssl3 | 3.5.7-r0 | Apache-2.0 |
| libstdc++ | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libtirpc | 1.3.5-r1 | BSD-3-Clause |
| libtirpc-conf | 1.3.5-r1 | BSD-3-Clause |
| libuuid | 2.42.1-r0 | BSD-3-Clause |
| libverto | 0.3.2-r2 | MIT |
| lsblk | 2.42.1-r0 | GPL-2.0-or-later |
| lvm2 | 2.03.35-r2 | GPL-2.0-or-later AND LGPL-2.1-or-later AND BSD-2-Clause |
| lvm2-libs | 2.03.35-r2 | GPL-2.0-or-later AND LGPL-2.1-or-later AND BSD-2-Clause |
| lzo | 2.10-r5 | GPL-2.0-or-later |
| mount | 2.42.1-r0 | GPL-3.0-or-later AND GPL-2.0-or-later AND GPL-2.0-only AND GPL-1.0-only AND LGPL-2.1-or-later AND BSD-1-Clause AND BSD-3-Clause AND BSD-4-Clause-UC AND MIT AND Public-Domain |
| mpdecimal | 4.0.1-r0 | BSD-2-Clause |
| musl | 1.2.6-r2 | MIT |
| musl-utils | 1.2.6-r2 | MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| ncurses-terminfo-base | 6.6_p20260516-r0 | X11 |
| nfs-utils | 2.6.4-r6 | GPL-2.0-only |
| ntfs-3g | 2026.2.25-r0 | GPL-2.0-only |
| ntfs-3g-libs | 2026.2.25-r0 | GPL-2.0-only |
| ntfs-3g-progs | 2026.2.25-r0 | GPL-2.0-only |
| popt | 1.19-r4 | MIT |
| python3 | 3.14.7-r1 | PSF-2.0 |
| readline | 8.3.3-r1 | GPL-3.0-or-later |
| rpcbind | 1.2.9-r0 | BSD-3-Clause |
| scanelf | 1.3.9-r1 | GPL-2.0-only |
| sqlite-libs | 3.53.2-r0 | blessing |
| xz-libs | 5.8.3-r0 | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later |
| zlib | 1.3.2-r0 | Zlib |
| zstd-libs | 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later |

The guest image is a reduced subset of Alpine Linux, containing only the
packages required to unlock and mount the supported filesystems. Notably
it contains no ZFS components: neither the `zfs` and `zfs-libs` packages
nor the `zfs.ko` and `spl.ko` kernel modules are distributed with Lukotta.

## Notes

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
must carry its own name and artwork. See TRADEMARK.md in the source.

BitLocker and Windows are trademarks of Microsoft Corporation. Linux is a
registered trademark of Linus Torvalds. macOS, Finder and Apple Silicon are
trademarks of Apple Inc. Lukotta is not affiliated with, endorsed by, or
sponsored by any of them, and names them only to say what it works with.

Generated 2026-08-20.
