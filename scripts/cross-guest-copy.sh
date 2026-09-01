#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Copy between two open volumes, each served by its own machine.
#
#   ./scripts/cross-guest-copy.sh <volume-a> <volume-b>
#
# Somebody with an NTFS drive and a Linux image open will drag files from one
# to the other, and nothing here had ever tried it. Every test until now copied
# from the Mac's own disk into one volume, which exercises one machine; this is
# two, with the host in the middle reading NFS from one and writing NFS to the
# other, and the two guests running different filesystem drivers.
#
# Measured on 2026-09-01, BitLocker/NTFS against an ext4 image:
#
#   NTFS -> ext4   6 files, 0 differing
#   ext4 -> NTFS   5 files byte-identical, and checked after ejecting both
#                  volumes and unlocking the drive again, so nothing was
#                  answered from the page cache
#
# And with a LUKS2 container holding btrfs open beside the same drive, which is
# encrypted on both sides and a different driver again:
#
#   NTFS  -> btrfs  7 files, 0 differing, 1s
#   btrfs -> NTFS   7 files, 0 differing, 13s
#
# And again with the Ubuntu shape, LUKS1 -> LVM -> btrfs, which reaches the
# volume through a logical volume rather than straight through the container:
#
#   NTFS   -> ROOTFS  7 files, 0 differing, 1s
#   ROOTFS -> NTFS    7 files, 0 differing, 13s
#
# And the Fedora shape, LUKS2 -> LVM -> btrfs:
#
#   NTFS -> LUKOTTATEST  7 files, 0 differing, 3s
#   LUKOTTATEST -> NTFS  7 files, 0 differing, 13s
#
# Three container layouts, each opened on its own and copied both ways. Note
# "on its own": killing one machine by pattern before starting the next leaves
# its mount in the table, answering `mount` and failing `stat`, which reads as a
# third volume being open when two are. Ask each mount whether it answers before
# counting it.
#
# Opening one of those without the app needs two things worth writing down.
# ALFS_PASSPHRASE reaches `mount` but not `list --decrypt`, which prompts on a
# terminal and ignores it -- the app drives that with expect, and so must
# anything else. And the identifier is the triple exactly as the listing prints
# it, "lvm:<vg>:<image-basename>:<lv>", resolved from the directory the image
# is in; a full path is refused with "Invalid LVM disk path".
#
# Both directions, because they are not the same path: one guest is reading
# what the other wrote, through two different drivers, and NTFS and ext4
# disagree about almost everything -- names, permissions, timestamps.
#
# The comparison is made after a fresh unlock for the same reason the copy is
# made at all: a byte read back from cache proves the cache works.
set -uo pipefail
A="${1:-}"; B="${2:-}"
[ -d "$A" ] && [ -d "$B" ] || { echo "usage: $0 <volume-a> <volume-b>" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0

payload() {  # directory
  mkdir -p "$1/deep/a/b"
  for i in 1 2 3; do dd if=/dev/urandom of="$1/big-$i.bin" bs=1048576 count=40 status=none; done
  printf 'x' > "$1/日本語のファイル名.txt"
  printf 'y' > "$1/Ünïcödé-präcömpösed.txt"
  printf 'z' > "$1/Ελληνικά-και-кириллица.txt"
  printf 'bottom' > "$1/deep/a/b/end.txt"
}

one_way() {  # from, to, label
  local from="$1" to="$2" label="$3"
  rm -rf "$from/cross-src" "$to/cross-dst"
  mkdir -p "$from/cross-src"
  payload "$from/cross-src"
  sync
  local start; start=$(date +%s)
  if ! ditto "$from/cross-src" "$to/cross-dst" 2>"$WORK/err"; then
    printf '  FAIL %s: %s\n' "$label" "$(head -1 "$WORK/err")"; fail=1; return
  fi
  local bad=0 n=0 rel
  while IFS= read -r f; do
    rel="${f#"$from/cross-src"/}"; n=$((n + 1))
    cmp -s "$f" "$to/cross-dst/$rel" || { printf '    DIFFERS %s\n' "$rel"; bad=$((bad + 1)); }
  done < <(find "$from/cross-src" -type f)
  printf '  %s: %s files, %s differing, %ss\n' "$label" "$n" "$bad" "$(( $(date +%s) - start ))"
  [ "$bad" -eq 0 ] || fail=1
  rm -rf "$from/cross-src" "$to/cross-dst"
}

one_way "$A" "$B" "$(basename "$A") -> $(basename "$B")"
one_way "$B" "$A" "$(basename "$B") -> $(basename "$A")"
if [ "$fail" -eq 0 ]; then
  echo "both directions intact"
else
  echo "FAILED"
  exit 1
fi
