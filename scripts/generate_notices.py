#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Build THIRD_PARTY_NOTICES.md from the shipped Alpine image."""
import sys, os, datetime

rootfs, out = sys.argv[1], sys.argv[2]
# The database captured from the image that actually ships. Falling back to the
# build machine's own copy silently produced notices listing components that had
# been removed, so a missing file is an error rather than a quiet substitution.
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
shipped = os.path.join(repo, "vendor", "engine", "alpine", "packages.db")
if not os.path.exists(shipped):
    sys.exit(
        "error: no vendored package database at "
        + shipped
        + "\n       run ./scripts/vendor-engine.sh first; refusing to generate "
        + "notices from anything other than what ships.")
db = shipped
pkgs, cur = [], {}
if os.path.exists(db):
    for line in open(db, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            if cur.get("P"): pkgs.append(cur)
            cur = {}
            continue
        if len(line) > 1 and line[1] == ":":
            cur[line[0]] = line[2:]
    if cur.get("P"): pkgs.append(cur)

rows = sorted({(p.get("P", ""), p.get("V", ""), p.get("L", "(unstated)")) for p in pkgs})


host = [
    ("anylinuxfs", "0.19.0, modified", "GPL-3.0-or-later",
     "https://github.com/nohajc/anylinuxfs"),
    # Linked into the engine and patched here, so the modified form is listed
    # beside what it is part of.
    ("imago", "0.2.3, modified", "MIT", "https://gitlab.com/hreitz/imago"),
    ("krun-devices", "0.1.0-1.19.3, modified", "Apache-2.0",
     "https://github.com/containers/libkrun"),
    ("libkrun and libkrunfw", "as embedded", "GPL-2.0-only AND LGPL-2.1-only",
     "https://github.com/containers/libkrun"),
    ("Linux kernel", "6.12.62", "GPL-2.0-only",
     "https://www.kernel.org/"),
    ("util-linux (libblkid)", "as embedded", "LGPL-2.1-or-later",
     "https://github.com/util-linux/util-linux"),
    ("gvisor-tap-vsock (gvproxy)", "as embedded", "Apache-2.0",
     "https://github.com/containers/gvisor-tap-vsock"),
    ("vmnet-helper", "as embedded", "Apache-2.0",
     "https://github.com/nirs/vmnet-helper"),
    # Shipped as a framework inside the app, not part of the engine. Its own
    # licence is MIT; it carries bsdiff (BSD-2-Clause) and an Ed25519
    # implementation (zlib/libpng) in Vendor, which travel with it.
    ("Sparkle", "2.9.6", "MIT AND BSD-2-Clause AND Zlib",
     "https://github.com/sparkle-project/Sparkle"),
    # Linked into the engine, and patched here. Listed so that the modified
    # form is visible beside the component it is part of.
]

lines = []
w = lines.append
w("# Third-Party Notices")
w("")
w("Lukotta is licensed under the GNU General Public License, version 3 or later.")
w("The application embeds the components listed below and redistributes them under")
w("their respective licences. The full text of the GNU General Public License")
w("accompanies the application.")
w("")
w("## Corresponding Source")
w("")
w("Lukotta is conveyed over a network. In accordance with section 6(d) of the GNU")
w("General Public License version 3, and the corresponding provision of section 3")
w("of version 2, the complete corresponding source for the application and for")
w("every GPL-licensed component embedded in it is offered from the same location as")
w("the application itself, at no additional charge.")
w("")
w("Each release is accompanied by that source. Requests may also be addressed to")
w("legal@lukotta.com.")
w("")
w('## Scope of the Corresponding Source')
w('')
w('Section 1 of version 3 of the GNU General Public License defines what the')
w('corresponding source comprises. Two consequences of that definition are')
w('recorded here.')
w('')
w("**Apple's compiler and frameworks.** A Major Component, as that section defines")
w('it, includes an essential component of the operating system on which the work')
w('runs and the compiler used to produce the work. The System Libraries of an')
w('executable include what is packaged with such a component and serves only to')
w('enable use of the work with it, or to implement a Standard Interface. The')
w('corresponding source expressly excludes System Libraries.')
w('')
w('The Swift and Objective-C toolchains supplied with Xcode are accordingly a')
w('Major Component, and AppKit, SwiftUI, Foundation and the other frameworks of')
w('macOS are System Libraries. Neither is conveyed with the application, and')
w('neither forms part of its corresponding source. Section 3 of version 2 makes')
w('equivalent provision.')
w('')
w('**The Linux guest.** The guest image and the application are not combined into')
w('a single work. They execute as separate programs in separate address spaces, on')
w('either side of a virtual machine boundary, and communicate over virtio devices')
w('and NFS. Storing them on one medium is aggregation, and does not bring either')
w("under the other's licence.")
w('')
w('Components of the guest licensed under GPL-2.0-only, among them the Linux')
w('kernel and busybox, are therefore distributed alongside an application licensed')
w('under GPL-3.0-or-later. Nothing of either is linked into the other. Each')
w('component is conveyed under its own licence, as listed below, and the')
w('corresponding source for each accompanies every release.')
w('')
w('## Conditions of Conveyance')
w('')
w('The application is conveyed under the GNU General Public License and under no')
w('further condition, as section 10 of version 3 requires. It is distributed')
w('directly, signed with a Developer ID and notarised by Apple. It is not')
w('distributed through the Mac App Store, whose terms would impose conditions on')
w('recipients that the same section does not permit.')
w('')
w('Signing and notarisation determine how macOS treats the binary the author')
w('distributes. They restrict neither building, modifying nor running the work:')
w('the build described in BUILDING.md produces a working application signed ad')
w('hoc, without a Developer ID and without notarisation.')
w("")
w('## Modifications to Redistributed Components')
w('')
w('The components listed below are redistributed in modified form. Each modified')
w('file carries a notice of that modification and its date, as required by section')
w('5(a) of the GNU General Public License version 3 and section 4(b) of the Apache')
w('License 2.0. The modifications are supplied as patches under `patches/`, and are')
w('included in the corresponding source alongside the unmodified upstream archives')
w('to which they apply.')
w('')
w('| Component | Licence | Date | Modification |')
w('| --- | --- | --- | --- |')
w('| anylinuxfs | GPL-3.0-or-later | 2026-08-22 | Recognition of the VMDK, VDI, VHD and VHDX disk-image formats |')
w('| vmproxy | GPL-3.0-or-later | 2026-08-22 | Unlocking of an encrypted volume detected inside a disk image |')
w('| imago | MIT | 2026-08-22 | Drivers for VDI, VHD and VHDX, the first two written as well as read; support for the sparse and stream-optimized forms of VMDK |')
w('| krun-devices | Apache-2.0 | 2026-08-22 | Selection of the VDI, VHD and VHDX drivers by disk-format number |')
w('')
w('Files added to imago by these modifications are licensed under the MIT terms of')
w("that crate and carry a notice recording it. Lukotta's own source is not")
w('licensed under those terms.')
w("")
w("## Host Components")
w("")
w("The following run on macOS, outside the Linux guest image. `vmproxy`,")
w("`init-rootfs` and the other helper programs distributed alongside them form")
w("part of anylinuxfs and are covered by its licence. The kernel images `Image`")
w("and `Image-4K` are Linux kernel binaries supplied by libkrunfw.")
w("")
w("| Component | Version | Licence | Source |")
w("| --- | --- | --- | --- |")
for name, ver, lic, url in host:
    w(f"| {name} | {ver} | {lic} | {url} |")
w("")
w("## Linux Guest Image")
w("")
w(f"The application embeds an Alpine Linux root filesystem containing the")
w(f"following {len(rows)} packages. Licence identifiers are reproduced from the")
w("package metadata contained in that filesystem. Source for each package is")
w("available from the Alpine Linux package archive at")
w("<https://pkgs.alpinelinux.org/> at the version stated.")
w("")
w("| Package | Version | Licence |")
w("| --- | --- | --- |")
for name, ver, lic in rows:
    w(f"| {name} | {ver} | {lic} |")
w("")
removed_path = os.path.join(os.path.dirname(db), "removed-packages.txt")
removed = []
if os.path.exists(removed_path):
    for line in open(removed_path, encoding="utf-8", errors="replace"):
        parts = line.split(None, 2)
        if len(parts) >= 2:
            removed.append((parts[0], parts[1], parts[2].strip() if len(parts) > 2 else ""))

if removed:
    # A notices document enumerates what is distributed. A table of absent
    # packages is build detail, and risks being read as a list of inclusions.
    # One sentence prevents the assumption that this is a stock Alpine image.
    w("The guest image is a reduced subset of Alpine Linux, containing only the")
    w("packages required to unlock and mount the supported filesystems. It contains")
    w("no ZFS components: neither the `zfs` and `zfs-libs` packages nor the `zfs.ko`")
    w("and `spl.ko` kernel modules are distributed with Lukotta.")
    w("")

w("## Notes")
w("")
w("- Licence identifiers are reproduced verbatim from each package's own")
w("  metadata. Packages under more than one licence retain the full expression")
w("  rather than being reduced to a single identifier.")
w("- `blessing` is the SPDX identifier for the SQLite licence, under which the")
w("  work is dedicated to the public domain.")
w("- `cryptsetup` is distributed under GPL-2.0-or-later with an OpenSSL")
w("  exception, as recorded in its licence expression.")
w("- The full licence text of each component accompanies it within the guest")
w("  image and within the corresponding source archive.")
w("")
w("")
w("## Trademarks")
w("")
w("Lukotta, the Lukotta wordmark and the Lukotta logo are trademarks of Clement")
w("Rahula and are not licensed under the GPL, as section 7(e) of that licence")
w("allows. The code may be forked and redistributed freely; a modified version")
w("must carry its own name and artwork. See TRADEMARKS.txt in the source.")
w("")
w("BitLocker and Windows are trademarks of Microsoft Corporation. Linux is a")
w("registered trademark of Linus Torvalds. macOS, Finder and Apple Silicon are")
w("trademarks of Apple Inc. Lukotta is not affiliated with, endorsed by, or")
w("sponsored by any of them, and names them to state what it works with.")
w("")
w(f"Generated {datetime.date.today().isoformat()}.")

open(out, "w").write("\n".join(lines) + "\n")
