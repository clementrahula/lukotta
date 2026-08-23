#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Reduce the Alpine guest image to the packages Lukotta can actually reach.

The image ships whatever anylinuxfs installs, which covers every filesystem it
supports. Lukotta unlocks BitLocker and mounts NTFS, so most of that is dead
weight — and every GPL package shipped is a package whose source must be
published alongside the release.

Removes packages outside the dependency closure of the roots below, deletes
their files, and rewrites the package database so it still describes what is
actually present.

    trim-image.py <rootfs> [--dry-run]
"""
import os, re, sys, shutil

ROOTS = [
    # BitLocker unlock
    "cryptsetup",
    # NTFS: ntfs-3g is the compatibility path for volumes ntfs3 refuses
    "ntfs-3g", "ntfs-3g-progs",
    # LUKS containers: Ubuntu, Debian, Fedora and openSUSE all put LVM inside
    "lvm2",
    # filesystems found inside LUKS containers
    "e2fsprogs", "btrfs-progs",
    # export back to macOS
    "nfs-utils", "rpcbind",
    # mounting and block-device identification
    "mount", "blkid", "lsblk",
    # base system
    "busybox", "busybox-binsh", "musl", "musl-utils", "bash",
    "alpine-baselayout", "alpine-baselayout-data", "alpine-keys",
    "alpine-release", "apk-tools", "ca-certificates-bundle",
]

def parse(db_path):
    pkgs, cur = [], {}
    for line in open(db_path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            if cur.get("P"): pkgs.append(cur)
            cur = {}
            continue
        if len(line) > 1 and line[1] == ":":
            k, v = line[0], line[2:]
            if k in ("D", "p"):
                cur[k] = (cur.get(k, "") + " " + v).strip()
            elif k == "F":
                cur.setdefault("_files", []).append([v, []])
            elif k == "R":
                if cur.get("_files"): cur["_files"][-1][1].append(v)
            else:
                cur[k] = v
    if cur.get("P"): pkgs.append(cur)
    return pkgs

def closure(pkgs):
    by_name = {p["P"]: p for p in pkgs}
    provides = {}
    for p in pkgs:
        provides[p["P"]] = p["P"]
        for tok in p.get("p", "").split():
            provides[re.split(r"[=<>]", tok)[0]] = p["P"]
    def deps(name):
        out = []
        for tok in by_name[name].get("D", "").split():
            if tok.startswith("!"): continue
            owner = provides.get(re.split(r"[=<>~]", tok)[0])
            if owner: out.append(owner)
        return out
    keep, stack = set(), [r for r in ROOTS if r in by_name]
    missing = [r for r in ROOTS if r not in by_name]
    if missing:
        print(f"  warning: roots not present in image: {', '.join(missing)}")
    while stack:
        n = stack.pop()
        if n in keep: continue
        keep.add(n)
        stack.extend(deps(n))
    return keep, by_name

def main():
    rootfs = sys.argv[1]
    dry = "--dry-run" in sys.argv
    db_path = os.path.join(rootfs, "lib/apk/db/installed")
    pkgs = parse(db_path)
    keep, by_name = closure(pkgs)
    drop = sorted(set(by_name) - keep)

    freed, removed = 0, 0
    for name in drop:
        for d, files in by_name[name].get("_files", []):
            for f in files:
                path = os.path.join(rootfs, d, f)
                if os.path.lexists(path):
                    try:
                        freed += os.path.getsize(path) if not os.path.islink(path) else 0
                    except OSError:
                        pass
                    removed += 1
                    if not dry:
                        try: os.remove(path)
                        except OSError: pass
    print(f"  keep {len(keep)} packages, drop {len(drop)}: {', '.join(drop)}")
    print(f"  {removed} files, {freed/1_048_576:.1f} MiB")

    if dry: return

    # Record the removal so the notices can state it from data rather than from
    # a hand-written list that drifts every time the roots change.
    manifest = os.path.join(os.path.dirname(rootfs), "removed-packages.txt")
    try:
        with open(manifest, "w") as fh:
            for name in drop:
                fh.write(f"{name} {by_name[name].get('V','')} {by_name[name].get('L','')}\n")
    except OSError:
        pass

    # Rewrite the database so it describes what is actually present. Otherwise
    # the notices would claim packages the image no longer ships.
    dropped = set(drop)
    records = open(db_path, encoding="utf-8", errors="replace").read().split("\n\n")
    kept_records = []
    for rec in records:
        if not rec.strip():
            continue
        name = next((l[2:].strip() for l in rec.splitlines() if l.startswith("P:")), None)
        if name is None or name in dropped:
            continue
        kept_records.append(rec.strip("\n"))
    open(db_path, "w", encoding="utf-8").write("\n\n".join(kept_records) + "\n\n")

    # Drop directories left empty by the removal.
    for d, _, files in os.walk(rootfs, topdown=False):
        if not files and not os.listdir(d):
            try: os.rmdir(d)
            except OSError: pass

if __name__ == "__main__":
    main()
