#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Reduce the Alpine guest image to the packages Lukotta can actually reach.

The image ships whatever anylinuxfs installs, which covers every filesystem it
supports. Lukotta reaches a smaller set -- BitLocker and NTFS, and ext, btrfs
and XFS bare or inside LUKS -- so most of that is dead weight — and every GPL package shipped is a package whose source must be
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
    # Linux software RAID. Kept because DiskWatcher.ourContent claims the Linux
    # RAID type GUID, which stops macOS offering to initialise a member disk --
    # an offer that is one click from destroying an array. Having claimed it,
    # the app owes the person a way to open it, and mdadm is what assembles the
    # array inside the guest. Claiming a disk and then refusing it is the one
    # combination that helps nobody. GPL-2, aggregated in the guest like the
    # rest of it.
    "mdadm",
    # The Linux filesystems the app offers to open, bare or inside LUKS. Each
    # is here for its repair tool, not its mkfs: a volume whose journal replays
    # at mount needs nothing, and a volume that fails to mount needs e2fsck or
    # xfs_repair present or there is no route but to hand the user an error.
    #
    # xfsprogs was missing from this list while the help sheet was telling
    # people the app opens "ext4, btrfs and XFS filesystems inside them", so a
    # repack would have deleted XFS's tools as unreachable weight.
    #
    # Naming a package here does not install it. This list only keeps what the
    # image already carries, and the anylinuxfs image carries neither e2fsprogs
    # nor xfsprogs -- see the note in vendor-engine.sh for putting them in.
    "e2fsprogs", "btrfs-progs", "xfsprogs",
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

    # Which directories are empty before anything is removed. A guest rootfs
    # ships /proc, /sys, /dev, /tmp and /run empty on purpose: the kernel and
    # the init mount them at boot. Only what the removal below empties may be
    # taken away, so they must be known apart beforehand.
    empty_already = {
        d for d, subdirs, files in os.walk(rootfs) if not subdirs and not files
    }

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

    # Drop directories left empty by the removal -- and only those. Removing
    # every empty directory takes the mount points with it, and a guest with no
    # /proc and no /sys boots far enough to answer questions with nothing.
    for d, _, files in os.walk(rootfs, topdown=False):
        if d in empty_already or files or os.listdir(d):
            continue
        try: os.rmdir(d)
        except OSError: pass

if __name__ == "__main__":
    main()
