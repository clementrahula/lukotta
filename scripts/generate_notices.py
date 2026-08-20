#!/usr/bin/env python3
"""Build THIRD_PARTY_NOTICES.md from the shipped Alpine image."""
import sys, os, datetime

rootfs, out = sys.argv[1], sys.argv[2]
# Prefer the database captured from the trimmed image that actually ships.
shipped = os.path.join(os.path.dirname(os.path.abspath(out)), "vendor/engine/alpine/packages.db")
db = shipped if os.path.exists(shipped) else os.path.join(rootfs, "lib/apk/db/installed")
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
    ("libkrun / libkrunfw", "bundled", "GPL-2.0-only AND LGPL-2.1-only",
     "https://github.com/containers/libkrun", "microVM hypervisor; libkrunfw bundles a Linux kernel image."),
    ("Linux kernel", "6.12.62", "GPL-2.0-only",
     "https://www.kernel.org/", "Bundled inside libkrunfw and shipped as a binary image."),
    ("util-linux (libblkid)", "see image", "LGPL-2.1-or-later",
     "https://github.com/util-linux/util-linux", "The single external dylib the engine links on the host."),
]

lines = []
w = lines.append
w("# Third-party notices")
w("")
w(f"Generated {datetime.date.today().isoformat()} by `scripts/generate-notices.sh`")
w("from the components embedded in the application bundle. Do not edit by hand.")
w("")
w("Lukotta itself is licensed **GPL-3.0-or-later** (see `LICENSE`). It embeds the")
w("components below and redistributes them under their own terms.")
w("")
w("## Corresponding source")
w("")
w("Lukotta is distributed over a network. Corresponding source is therefore")
w("provided under GPL-3.0 section 6(d), and the equivalent provision of GPL-2.0")
w("section 3: the complete corresponding source for the binary and for every")
w("GPL-licensed component it embeds is offered from the same place as the")
w("application, at no additional charge.")
w("")
w("Each release includes that source. Requests may also be sent to")
w("**lukotta@rahula.dev**.")
w("")
w("## Host components")
w("")
w("| Component | Version | Licence | Source |")
w("| --- | --- | --- | --- |")
for name, ver, lic, url, _ in host:
    w(f"| {name} | {ver} | {lic} | {url} |")
w("")
for name, ver, lic, url, note in host:
    w(f"- **{name}** — {note}")
w("")
w("## Linux guest image (Alpine Linux)")
w("")
w(f"{len(rows)} packages are shipped inside the embedded Alpine root filesystem,")
w("which is trimmed by `tools/trim-image.py` to the dependency closure of what")
w("Lukotta actually uses — the upstream image carries 76.")
w("Licence strings are taken verbatim from the image's own package database.")
w("Source for each is available from the Alpine Linux package archive")
w("(<https://pkgs.alpinelinux.org/>) at the exact version listed.")
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
    w("### Removed from the upstream image")
    w("")
    w("The upstream image supports every filesystem anylinuxfs handles. Packages")
    w("outside the dependency closure of the tooling Lukotta uses are removed by")
    w("`scripts/trim-image.py` and are not distributed:")
    w("")
    w("| Package | Version | Licence |")
    w("| --- | --- | --- |")
    for name, ver, lic in sorted(removed):
        w(f"| {name} | {ver} | {lic or '(unstated)'} |")
    w("")
    if any(n.startswith("zfs") for n, _, _ in removed):
        w("This includes ZFS. The upstream image ships `zfs` and `zfs-libs`")
        w("(CDDL-1.0) together with the `zfs.ko` and `spl.ko` kernel modules.")
        w("Lukotta does not use ZFS and does not distribute those components.")
        w("")

w("## Notes")
w("")
w("- Licence identifiers are reproduced verbatim from each package's own")
w("  metadata. Multi-licensed packages retain the full expression rather than")
w("  being reduced to a single identifier.")
w("- `cryptsetup` is distributed under GPL-2.0-or-later with an OpenSSL")
w("  exception, as recorded in its licence expression.")
w("- Full licence texts accompany each component in the Alpine image and in the")
w("  corresponding source archive.")

open(out, "w").write("\n".join(lines) + "\n")
