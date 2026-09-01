#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Copy a corpus onto an opened drive and read every byte of it back.
#
#     ./scripts/copy-torture.sh /Volumes/YOUR_DRIVE
#
# "The copy finished" and "the data arrived" are different claims, and a file
# count answers only the first. A copy that lands the right number of files
# with the wrong bytes in them passes every check anybody was making before
# this existed.
#
# The corpus is not 26 identical large files. It is the shapes a filesystem
# bridge actually breaks on: names NTFS keeps as UTF-16 and macOS hands over as
# decomposed UTF-8, names near the 255-byte limit, trailing dots that Windows
# refuses, sizes exactly on and one either side of the block and transfer
# boundaries, a sparse file that must not arrive fully allocated, empty files,
# two thousand small ones where metadata dominates rather than data, and a
# directory deep enough to make the path long.
#
# Everything is invented here and nothing is read off the machine, so the same
# corpus appears on anybody's drive.
#
# Measured through a BitLocker/NTFS stick on 2026-09-01: 2024 of 2024 files
# byte-identical, nothing missing -- and the sparse gigabyte arrived fully
# allocated, 8 blocks at the source against 2097153 at the destination.
#
# The large-file half was checked the same day and in three passes, which is
# what the claim actually needs: thirteen gigabytes in twenty-six files copied,
# all twenty-six matching by SHA-256 through the mount they were written to,
# the drive then ejected and unlocked again in eight seconds, and all
# twenty-six matching a second time through the new mount.
#
# The third pass is the one worth keeping. A copy that lands intact and leaves
# the volume unopenable afterwards is not a success, and until the drive could
# be closed and reopened from a shell nobody had ever looked.
#
# That last one is the protocol rather than a fault here. NFSv3 has no way to
# say "this range is a hole": the client sends the zeros and the server writes
# them, so a file that occupied four kilobytes occupies a gigabyte afterwards.
# It matters for anything macOS keeps sparse -- a disk image most of all -- and
# it is worth knowing before a copy fills a drive that had room for it.
#
# So the block count is checked separately from the content. A sparse file that
# arrives fully allocated is still byte-identical, and every other check here
# would call it a pass.
set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "usage: $0 <mounted-volume>" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "error: $TARGET is not a directory" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/torture"
DST="$TARGET/lukotta-torture"

mkdir -p "$SRC/names" "$SRC/sizes" "$SRC/sparse" "$SRC/many"

# Names. Which normalisation arrived matters as much as which characters did.
printf 'a' > "$SRC/names/simple.txt"
printf 'b' > "$SRC/names/with space and (parens).txt"
printf 'c' > "$SRC/names/Ünïcödé-präcömpösed.txt"
printf 'd' > "$SRC/names/日本語のファイル名.txt"
printf 'e' > "$SRC/names/Ελληνικά-και-кириллица.txt"
printf 'f' > "$SRC/names/emoji-🗄️-archive.txt"
printf 'g' > "$SRC/names/$(printf 'n%.0s' $(seq 1 200)).txt"
printf 'h' > "$SRC/names/.leading-dot"
printf 'i' > "$SRC/names/trailing.dots..."

# On and around the block and transfer sizes.
for n in 0 1 511 512 513 4095 4096 4097 65535 65536 131071 131072 131073; do
  head -c "$n" /dev/urandom > "$SRC/sizes/exact-$n.bin"
done

# Mostly hole. A gigabyte apparent, a few blocks real.
: > "$SRC/sparse/hole-1g.bin"
printf 'end' | dd of="$SRC/sparse/hole-1g.bin" bs=1 seek=1073741824 conv=notrunc status=none

# Where metadata is the work rather than the data.
for i in $(seq 1 2000); do head -c 512 /dev/urandom > "$SRC/many/f$i.bin"; done

# Long path as much as deep tree.
deep="$SRC/deep"; mkdir -p "$deep"
for i in $(seq 1 24); do deep="$deep/level$i"; mkdir -p "$deep"; done
printf 'bottom' > "$deep/bottom.txt"

files=$(find "$SRC" -type f | wc -l | tr -d ' ')
printf 'corpus: %s files, %s apparent\n' "$files" "$(du -sh "$SRC" | cut -f1)"

# The sparse gigabyte is four kilobytes here and a gigabyte on the far side --
# NFSv3 has no way to say "this range is a hole" -- so the space needed is the
# apparent size, not the size on disk. Said before copying rather than as ENOSPC
# on one file two thousand files in, which reads as a fault and is arithmetic.
need=$(find "$SRC" -type f -printf '%s\n' | awk '{s+=$1} END{print int(s/1048576)+64}')
have=$(df -m "$TARGET" | awk 'NR==2 {print $4}')
printf 'needs about %s MB, %s MB free\n' "$need" "$have"
if [ "${have:-0}" -lt "$need" ]; then
  echo "error: not enough room. The sparse file arrives fully allocated, so the" >&2
  echo "       corpus needs its apparent size, not its size on disk." >&2
  exit 1
fi

# ditto rather than cp: it goes through copyfile(3), which is the path Finder
# uses, so extended attributes and the sidecars travel with the data. cp is a
# gentler workload than anybody actually generates.
rm -rf "$DST"
printf 'copying to %s\n' "$DST"
start=$(date +%s)
ditto "$SRC" "$DST"
printf 'copied in %ss\n' "$(( $(date +%s) - start ))"

# Read it back through the mount, which is the path a person opening the file
# afterwards would take, rather than out of the guest.
bad=0; good=0; missing=0
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  d="$DST/$rel"
  if [ ! -f "$d" ]; then printf 'MISSING %s\n' "$rel"; missing=$((missing+1)); continue; fi
  if ! cmp -s "$f" "$d"; then printf 'DIFFERS %s\n' "$rel"; bad=$((bad+1)); continue; fi
  good=$((good+1))
done < <(find "$SRC" -type f)

# A sparse file that arrives fully allocated is still byte-identical, so it is
# checked separately or the one thing it tests goes unnoticed.
#
# GNU stat and BSD stat spell the same field differently, and a Mac with
# coreutils ahead of /usr/bin has the GNU one. -f means "format" to one and
# "the filesystem, not the file" to the other, so guessing wrong is silent
# nonsense rather than an error.
blocks() { stat -c %b "$1" 2>/dev/null || stat -f %b "$1" 2>/dev/null || echo -1; }
sblocks=$(blocks "$SRC/sparse/hole-1g.bin")
dblocks=$(blocks "$DST/sparse/hole-1g.bin")
printf 'sparse: %s blocks at source, %s at destination\n' "$sblocks" "$dblocks"

printf '%s identical, %s differing, %s missing\n' "$good" "$bad" "$missing"
[ "$bad" -eq 0 ] && [ "$missing" -eq 0 ]
