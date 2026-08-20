#!/usr/bin/env python3
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
    ("anylinuxfs", "0.19.0", "GPL-3.0-or-later",
     "https://github.com/nohajc/anylinuxfs", "Mounts the drive inside a microVM and exports it over NFS."),
    ("libkrun and libkrunfw", "as embedded", "GPL-2.0-only AND LGPL-2.1-only",
     "https://github.com/containers/libkrun", "microVM hypervisor; libkrunfw bundles a Linux kernel image."),
    ("Linux kernel", "6.12.62", "GPL-2.0-only",
     "https://www.kernel.org/", "Bundled inside libkrunfw and shipped as a binary image."),
    ("util-linux (libblkid)", "as embedded", "LGPL-2.1-or-later",
     "https://github.com/util-linux/util-linux", "The single external dylib the engine links on the host."),
]

lines = []
w = lines.append
w("# Third-Party Notices")
w("")
w("Lukotta is licensed under the GNU General Public License, version 3 or")
w("later. The application embeds the components listed below and redistributes")
w("them under their respective licences. The full text of the GNU General Public")
w("License accompanies the application.")
w("")
w("## Corresponding Source")
w("")
w("Lukotta is conveyed over a network. In accordance with section 6(d) of the")
w("GNU General Public License version 3, and the corresponding provision of")
w("section 3 of version 2, the complete corresponding source for the")
w("application and for every GPL-licensed component embedded in it is offered")
w("from the same location as the application itself, at no additional charge.")
w("")
w("Each release is accompanied by that source. Requests may also be addressed")
w("to lukotta@rahula.dev.")
w("")
w("## Host Components")
w("")
w("| Component | Version | Licence | Source |")
w("| --- | --- | --- | --- |")
for name, ver, lic, url, _ in host:
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
    w("packages required to unlock and mount the supported filesystems. Notably")
    w("it contains no ZFS components: neither the `zfs` and `zfs-libs` packages")
    w("nor the `zfs.ko` and `spl.ko` kernel modules are distributed with Lukotta.")
    w("")

w("## Notes")
w("")
w("- Licence identifiers are reproduced verbatim from each package's own")
w("  metadata. Packages under more than one licence retain the full expression")
w("  rather than being reduced to a single identifier.")
w("- `cryptsetup` is distributed under GPL-2.0-or-later with an OpenSSL")
w("  exception, as recorded in its licence expression.")
w("- The full licence text of each component accompanies it within the guest")
w("  image and within the corresponding source archive.")
w("")
w(f"Generated {datetime.date.today().isoformat()}.")

open(out, "w").write("\n".join(lines) + "\n")
