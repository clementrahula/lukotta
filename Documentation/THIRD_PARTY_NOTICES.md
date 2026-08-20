# Third-party notices

Generated 2026-08-20 by `scripts/generate-notices.sh`
from the components embedded in the application bundle. Do not edit by hand.

Lukotta itself is licensed **GPL-3.0-or-later** (see `LICENSE`). It embeds the
components below and redistributes them under their own terms.

## Corresponding source

Lukotta is distributed over a network. Corresponding source is therefore
provided under GPL-3.0 section 6(d), and the equivalent provision of GPL-2.0
section 3: the complete corresponding source for the binary and for every
GPL-licensed component it embeds is offered from the same place as the
application, at no additional charge.

Each release includes that source. Requests may also be sent to
**lukotta@rahula.dev**.

## Host components

| Component | Version | Licence | Source |
| --- | --- | --- | --- |
| anylinuxfs | 0.19.0 | GPL-3.0-or-later | https://github.com/nohajc/anylinuxfs |
| libkrun / libkrunfw | bundled | GPL-2.0-only AND LGPL-2.1-only | https://github.com/containers/libkrun |
| Linux kernel | 6.12.62 | GPL-2.0-only | https://www.kernel.org/ |
| util-linux (libblkid) | see image | LGPL-2.1-or-later | https://github.com/util-linux/util-linux |

- **anylinuxfs** — Mounts the drive inside a microVM and exports it over NFS.
- **libkrun / libkrunfw** — microVM hypervisor; libkrunfw bundles a Linux kernel image.
- **Linux kernel** — Bundled inside libkrunfw and shipped as a binary image.
- **util-linux (libblkid)** — The single external dylib the engine links on the host.

## Linux guest image (Alpine Linux)

76 packages are shipped inside the embedded Alpine root filesystem,
which is trimmed by `tools/trim-image.py` to the dependency closure of what
Lukotta actually uses — the upstream image carries 76.
Licence strings are taken verbatim from the image's own package database.
Source for each is available from the Alpine Linux package archive
(<https://pkgs.alpinelinux.org/>) at the exact version listed.

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
| libintl | 1.0-r0 | LGPL-2.1-or-later |
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
| lz4-libs | 1.10.0-r1 | BSD-2-Clause AND GPL-2.0-or-later |
| lzo | 2.10-r5 | GPL-2.0-or-later |
| mdadm | 4.3-r3 | GPL-2.0-only |
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
| pyc | 3.14.7-r1 | PSF-2.0 |
| python3 | 3.14.7-r1 | PSF-2.0 |
| python3-pyc | 3.14.7-r1 | PSF-2.0 |
| python3-pycache-pyc0 | 3.14.7-r1 | PSF-2.0 |
| readline | 8.3.3-r1 | GPL-3.0-or-later |
| rpcbind | 1.2.9-r0 | BSD-3-Clause |
| scanelf | 1.3.9-r1 | GPL-2.0-only |
| sqlite-libs | 3.53.2-r0 | blessing |
| squashfs-tools | 4.7.5-r0 | GPL-2.0-or-later |
| ssl_client | 1.37.0-r31 | GPL-2.0-only |
| xz-libs | 5.8.3-r0 | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later |
| zfs | 2.4.3-r0 | CDDL-1.0 |
| zfs-libs | 2.4.3-r0 | CDDL-1.0 |
| zlib | 1.3.2-r0 | Zlib |
| zstd-libs | 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later |

## Notes

- Licence identifiers are reproduced verbatim from each package's own
  metadata. Multi-licensed packages retain the full expression rather than
  being reduced to a single identifier.
- `cryptsetup` is distributed under GPL-2.0-or-later with an OpenSSL
  exception, as recorded in its licence expression.
- Full licence texts accompany each component in the Alpine image and in the
  corresponding source archive.
