#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A volume Windows left dirty is opened writable, and the data is still there.
#
#   ./scripts/dirty-ntfs-repair.sh [outdir]
#
# The app clears the dirty flag rather than demoting the volume to read-only,
# because somebody who asked for writable is owed writable. The tests cover
# what the repair refuses -- a hibernated volume, a volume ntfsfix -n will not
# vouch for -- by running the real command against stubs. What they do not
# cover is the thing that actually matters: that a volume which goes through
# the repair still holds every byte it held before.
#
# ntfsfix does not replay the NTFS journal. Nothing on Linux does; it discards
# it. So "the flag is cleared and it mounts" is not the claim worth making, and
# this makes the other one: known contents, written and checksummed before the
# volume is left dirty, compared byte for byte after the app has opened it.
#
# The volume is made dirty the way a real one becomes dirty -- by the machine
# holding it going away mid-write, rather than by flipping a bit and hoping the
# result resembles one.
#
# On an image throughout. Nothing here touches a drive anybody owns.
set -uo pipefail
OUT="${1:-$HOME/.lukotta-testvols}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
mkdir -p "$OUT"
IMG="$OUT/dirty-ntfs.img"
WORK="$(mktemp -d)"
trap 'pkill -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

# A fresh NTFS volume, made by the guest, which is the only thing here that
# carries mkfs.ntfs.
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek=600 2>/dev/null
"$ENGINE" shell "$IMG" -c 'mkfs.ntfs -Q -L DIRTYTEST /dev/vda >/dev/null 2>&1 && echo made' \
  > "$WORK/mkfs.log" 2>&1
grep -q made "$WORK/mkfs.log" || { echo "error: could not make the volume" >&2; cat "$WORK/mkfs.log" >&2; exit 1; }
echo "made a clean NTFS volume"

# The engine names a share after what it was made from -- "<image>-img.local:
# /mnt/LABEL" for a file, "<device>.local:/mnt/LABEL" for a drive -- and only a
# mount made by hand against the guest's address says 172.27. Polling for the
# address therefore waited out its timeout on a volume that had mounted
# perfectly well, and reported that the volume would not open.
open_it() {  # extra engine args
  pkill -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1; sleep 3
  nohup "$ENGINE" mount --ignore-permissions -w false -t ntfs3 "$@" "$IMG" > "$WORK/engine.log" 2>&1 &
  for _ in $(seq 1 40); do mount | grep -q ':/mnt/' && return 0; sleep 2; done
  return 1
}
where() { mount | awk '/:\/mnt\// {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | tail -1; }

# Known contents, checksummed before anything goes wrong with the volume.
open_it -a lukottatuned || { echo "error: clean volume would not open" >&2; exit 1; }
VOL="$(where)"; echo "opened clean at $VOL"
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 40); do head -c 200000 /dev/urandom > "$SRC/f$i.bin"; done
printf 'the byte that must survive' > "$SRC/witness.txt"
ditto "$SRC" "$VOL/before" >/dev/null 2>&1
sync
BEFORE="$WORK/before.sums"
(cd "$SRC" && find . -type f -exec shasum -a 256 {} \; | sort) > "$BEFORE"
echo "wrote $(wc -l < "$BEFORE" | tr -d ' ') files and recorded their sums"

# Dirty it the way a real volume gets dirty: take the machine away mid-write.
dd if=/dev/urandom of="$VOL/interrupted.bin" bs=1048576 count=200 2>/dev/null &
writer=$!
sleep 3
pkill -9 -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1
kill -9 "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
umount -f "$VOL" >/dev/null 2>&1
sleep 3
echo "machine killed mid-write; the volume should now be dirty"

# Confirm it really is, rather than assuming the kill was enough.
"$ENGINE" shell "$IMG" -c 'ntfsfix -n /dev/vda 2>&1 | head -20' > "$WORK/state.log" 2>&1
if grep -qiE 'dirty|unclean|journal|logfile' "$WORK/state.log"; then
  echo "confirmed dirty"
else
  echo "NOTE: the volume did not come back dirty; the rest still runs but proves less"
  sed -n '1,6p' "$WORK/state.log"
fi

# Open it the way the app does when a volume is dirty.
if open_it -a lukottarepair; then
  VOL="$(where)"; echo "opened dirty volume at $VOL"
else
  echo "FAIL: the app could not open the dirty volume at all" >&2; exit 1
fi

# Writable, because that is what was asked for.
if printf 'writable' > "$VOL/after-repair.txt" 2>/dev/null; then
  echo "ok   the repaired volume takes a write"
else
  echo "FAIL the repaired volume is read-only" >&2; fail=1
fi

# And every byte still there.
AFTER="$WORK/after.sums"
(cd "$VOL/before" && find . -type f -exec shasum -a 256 {} \; | sort) > "$AFTER"
if diff -q "$BEFORE" "$AFTER" >/dev/null 2>&1; then
  echo "ok   all $(wc -l < "$AFTER" | tr -d ' ') files byte-identical after the repair"
else
  echo "FAIL the repair changed the data:" >&2
  diff "$BEFORE" "$AFTER" | head -10 >&2
  fail=1
fi
if [ -z "${fail:-}" ]; then
  echo "PASS"
else
  echo "FAILED"
  exit 1
fi
