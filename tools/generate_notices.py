#!/usr/bin/env python3
"""Build THIRD_PARTY_NOTICES.md from the shipped Alpine image."""
import sys, os, datetime

rootfs, out = sys.argv[1], sys.argv[2]
db = os.path.join(rootfs, "lib/apk/db/installed")
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
zfs = [r for r in rows if r[0].startswith("zfs")]
rows = [r for r in rows if not r[0].startswith("zfs")]

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
w(f"Generated {datetime.date.today().isoformat()} by `tools/generate-notices.sh` from the")
w("components actually embedded in the application bundle.")
w("")
w("Lukotta itself is licensed **GPL-3.0-or-later** (see `LICENSE`). It embeds the")
w("components below and redistributes them under their own terms.")
w("")
w("## Written offer for source code")
w("")
w("As required by GPL-2.0 section 3 and GPL-3.0 section 6, the complete")
w("corresponding source code for every GPL component listed here is available.")
w("Source for Lukotta is at the project repository. For the embedded components,")
w("open an issue on the project repository, or write to **lukotta@rahula.dev**,")
w("and you will be sent the complete corresponding source for the exact versions")
w("shipped, for at least three years from the date of distribution, at no more")
w("than the cost of the transfer.")
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
w(f"{len(rows)} packages are shipped inside the embedded Alpine root filesystem.")
w("Licence strings are taken verbatim from the image's own package database.")
w("Source for each is available from the Alpine Linux package archive")
w("(<https://pkgs.alpinelinux.org/>) at the exact version listed.")
w("")
w("| Package | Version | Licence |")
w("| --- | --- | --- |")
for name, ver, lic in rows:
    w(f"| {name} | {ver} | {lic} |")
w("")
if zfs:
    w("### Removed from the shipped image")
    w("")
    w("ZFS is **not** shipped. The upstream Alpine image includes `zfs` and")
    w("`zfs-libs` (CDDL-1.0) together with `zfs.ko` and `spl.ko`, which combine")
    w("CDDL-licensed kernel modules with a GPL-2.0 kernel. Lukotta never touches")
    w("ZFS, so `vendor-engine.sh` removes those components rather than")
    w("redistribute that combination.")
    w("")
w("## Notes")
w("")
w("- `cryptsetup` carries an OpenSSL exception, recorded in its licence string.")
w("- Several packages are multi-licensed; the strings above preserve the full")
w("  expression rather than reducing it to a single identifier.")
w("- Full licence texts are distributed inside the Alpine image and with each")
w("  upstream source archive.")

open(out, "w").write("\n".join(lines) + "\n")
