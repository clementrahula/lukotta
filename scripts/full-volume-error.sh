#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What a person is told when a volume runs out of room.
#
# WHY
#
# A copy onto one of twelve failed with "Stale NFS file handle", twice at the
# same file -- the 38th of sixty, about 3.8 MB into a 6 MB copy -- and only on
# volumes an earlier run had left nearly full. A volume that fills should say
# so: ENOSPC, which Finder draws as "not enough free space". A stale file
# handle is not that. It is the error you get when the thing you were writing
# to has ceased to exist, it does not heal, and Finder has nothing sensible to
# draw for it.
#
# So this fills a volume deliberately, to a known margin, and copies more than
# fits. What comes back is what a person would be told.
#
#   ./scripts/full-volume-error.sh              # leave 4 MB, copy 6 MB
#   MARGIN_MB=1 ./scripts/full-volume-error.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive8.img}"
MARGIN_MB="${MARGIN_MB:-4}"
FILES="${FILES:-60}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/crowd/$IMAGE"

[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
if hdiutil info 2>/dev/null | /usr/bin/grep -q "$IMG"; then
  echo "error: $IMAGE is already attached; detach it first" >&2; exit 2
fi

WORK="$(mktemp -d)"
DEV=""
clean_up() {
  point="$(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | head -1)"
  if [ -n "${point:-}" ]; then
    rm -rf "$point/fill" "$point/spill" >/dev/null 2>&1
    umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1
  fi
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force -quiet >/dev/null 2>&1
  rm -rf "$WORK"
}
trap clean_up EXIT

DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "error: would not attach" >&2; exit 2; }
timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "error: did not open: $(tail -1 "$WORK/open.log")" >&2; exit 2; }
POINT="$(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | head -1)"
[ -n "${POINT:-}" ] || { echo "error: opened and nothing is served" >&2; exit 2; }

echo "$POINT: $(df -h "$POINT" | tail -1 | awk '{print $4 " free of " $2}')"

# Filled to the margin, one megabyte at a time so the last one lands where it
# is meant to rather than wherever a big write happens to stop.
mkdir -p "$POINT/fill"
n=0
while :; do
  free_mb=$(df -m "$POINT" | tail -1 | awk '{print $4}')
  [ "${free_mb:-0}" -le "$MARGIN_MB" ] && break
  n=$((n + 1))
  if ! head -c 1048576 /dev/urandom > "$POINT/fill/pad$n" 2>"$WORK/fill.err"; then
    echo "filling stopped at $n MB: $(head -1 "$WORK/fill.err")"
    break
  fi
  [ "$n" -gt 200 ] && break
done
echo "filled with $n MB; $(df -h "$POINT" | tail -1 | awk '{print $4}') free"

# Now copy more than fits, exactly as the crowd harness does.
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 "$FILES"); do head -c 100000 /dev/urandom > "$SRC/f$i.bin"; done

echo
echo "copying $FILES files (about $((FILES / 10)) MB) into what is left"
ditto "$SRC" "$POINT/spill" > "$WORK/ditto.log" 2>&1
rc=$?
arrived=$(ls -1 "$POINT/spill" 2>/dev/null | wc -l | tr -d ' ')
echo "ditto exited $rc, $arrived of $FILES arrived"
echo "what it said:"
sed 's/^/    /' "$WORK/ditto.log" | head -5

echo
if /usr/bin/grep -qi 'stale' "$WORK/ditto.log"; then
  echo "RESULT: a full volume reports a stale file handle, not a full volume" >&2
  exit 1
elif /usr/bin/grep -qiE 'no space|not enough' "$WORK/ditto.log"; then
  echo "RESULT: a full volume says it is full, which is what it should say"
elif [ "$rc" -eq 0 ]; then
  echo "RESULT: everything fitted; the margin was too generous to test anything" >&2
  exit 1
else
  echo "RESULT: the copy failed with something else; see above" >&2
  exit 1
fi
