#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# What a volume costs, in the four numbers that decide whether it feels native.
#
#   ./scripts/volume-bench.sh /Volumes/SOMETHING          6000 files, 800 MB
#   ./scripts/volume-bench.sh /Volumes/SOMETHING 20000    a larger tree
#   COUNT=6000 BIG_MB=800 ./scripts/volume-bench.sh <path>
#
# The four are the ones the architecture is being judged on: creating many small
# files, listing them, deleting them, and streaming a large one both ways.
# Deletion is the one v1 fails -- 5000 ms for 6000 files over NFS against 590 ms
# on APFS -- so it is measured on its own rather than folded into a total.
#
# It works inside a directory of its own and takes it away afterwards, so it can
# be pointed at a volume with things on it. It refuses a path that is not a
# mount point of its own or a directory under one, because the interesting
# targets are all volumes and a stray run inside a home directory is not worth
# the convenience.
set -uo pipefail

TARGET="${1:-}"
COUNT="${2:-${COUNT:-6000}}"
BIG_MB="${BIG_MB:-800}"

[ -n "$TARGET" ] || { echo "usage: $0 <mounted-path> [file-count]" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "error: $TARGET is not a directory" >&2; exit 1; }
[ -w "$TARGET" ] || { echo "error: $TARGET is not writable" >&2; exit 1; }

# Milliseconds. `date +%s%N` is GNU; BSD date has no nanoseconds, so python
# holds the clock. One interpreter start per measurement, subtracted out by
# taking the reading either side of the work rather than around it.
now_ms() { /usr/bin/python3 -c 'import time; print(int(time.time()*1000))'; }

WORK="$TARGET/lukotta-bench-$$"
mkdir -p "$WORK" || { echo "error: cannot write into $TARGET" >&2; exit 1; }
cleanup() { rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT

printf 'volume-bench: %s\n' "$TARGET"
printf '  filesystem: %s\n' \
  "$(/sbin/mount | awk -v p="$TARGET" '$3==p || index(p, $3)==1 {print $0}' | tail -1)"
printf '  %s files of 512 B, plus one of %s MB\n\n' "$COUNT" "$BIG_MB"

# ---- create -----------------------------------------------------------------
# Written by one process in a loop, which is what a copy of a folder of small
# files actually looks like from the filesystem's side: open, write, close,
# one after another. Parallelism would measure a different thing.
mkdir -p "$WORK/many"
start="$(now_ms)"
/usr/bin/python3 - "$WORK/many" "$COUNT" <<'PY'
import os, sys
directory, count = sys.argv[1], int(sys.argv[2])
blob = b"x" * 512
for i in range(count):
    with open(os.path.join(directory, f"f{i:06d}"), "wb") as handle:
        handle.write(blob)
PY
create_ms=$(( $(now_ms) - start ))

# ---- list -------------------------------------------------------------------
# With attributes, because that is what Finder asks for when it opens a folder,
# and it is the operation NFS answers one file at a time.
start="$(now_ms)"
ls -lR "$WORK/many" >/dev/null 2>&1
list_ms=$(( $(now_ms) - start ))

# ---- delete -----------------------------------------------------------------
start="$(now_ms)"
rm -rf "$WORK/many"
delete_ms=$(( $(now_ms) - start ))

# ---- stream out -------------------------------------------------------------
start="$(now_ms)"
dd if=/dev/zero of="$WORK/big" bs=1m count="$BIG_MB" 2>/dev/null
sync
write_ms=$(( $(now_ms) - start ))

# ---- stream in --------------------------------------------------------------
# The cache is not emptied between the two: doing that needs root, and the
# comparison here is between volumes measured the same way, not an absolute.
start="$(now_ms)"
dd if="$WORK/big" of=/dev/null bs=1m 2>/dev/null
read_ms=$(( $(now_ms) - start ))
rm -f "$WORK/big"

per_create=$(/usr/bin/python3 -c "print(f'{$create_ms/$COUNT*1000:.0f}')")
per_delete=$(/usr/bin/python3 -c "print(f'{$delete_ms/$COUNT*1000:.0f}')")
write_mbs=$(/usr/bin/python3 -c "print(f'{$BIG_MB/max($write_ms,1)*1000:.0f}')")
read_mbs=$(/usr/bin/python3 -c "print(f'{$BIG_MB/max($read_ms,1)*1000:.0f}')")

printf '  create %-6s files   %8s ms   %6s us/file\n' "$COUNT" "$create_ms" "$per_create"
printf '  list   %-6s files   %8s ms\n' "$COUNT" "$list_ms"
printf '  delete %-6s files   %8s ms   %6s us/file\n' "$COUNT" "$delete_ms" "$per_delete"
printf '  write  %-6s MB      %8s ms   %6s MB/s\n' "$BIG_MB" "$write_ms" "$write_mbs"
printf '  read   %-6s MB      %8s ms   %6s MB/s\n' "$BIG_MB" "$read_ms" "$read_mbs"
