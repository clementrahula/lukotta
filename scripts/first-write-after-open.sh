#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The first write after a volume is opened, over and over.
#
# WHY
#
# Twice on 2026-09-03 a volume of twelve failed its readback with "Stale NFS
# file handle" -- the listing found the file and the handle to it was already
# dead. Both times it was the copy the twelve-volume harness makes immediately
# after the last volume opens, and both times it was the same image.
#
# Against volumes that had been open for a while, 324 copies of the same shape
# were clean: every one visible 60 ms after it returned. So what the fault
# wants is not the copy and not the crowd -- it is a copy that lands on a
# volume that has only just been opened. This does that one thing, on one
# volume, in cycles of about fifteen seconds instead of four minutes.
#
#   ./scripts/first-write-after-open.sh              # 20 cycles on drive8
#   IMAGE=drive3.img CYCLES=40 ./scripts/first-write-after-open.sh
#   SETTLE=5 ./scripts/first-write-after-open.sh     # wait before writing
#
# SETTLE is the question this exists to answer. If the fault disappears when
# the copy waits a few seconds after the mount, then something the mount starts
# is still finishing when the client is already being handed file handles, and
# the fix is to make the open return only once that has finished -- not to make
# anybody wait.
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive8.img}"
CYCLES="${CYCLES:-20}"
FILES="${FILES:-60}"
SETTLE="${SETTLE:-0}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"

IMG="$OUT/crowd/$IMAGE"
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }

WORK="$(mktemp -d)"
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 "$FILES"); do head -c 100000 /dev/urandom > "$SRC/f$i.bin"; done
(cd "$SRC" && find . -type f -exec shasum -a 256 {} \; | sort) > "$WORK/before.sums"

DEV=""
release() {
  point="$(mount | /usr/bin/grep -oE "/Volumes/[A-Z0-9]*" | /usr/bin/grep -i crowd | head -1)"
  [ -n "${point:-}" ] && { umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1; }
  [ -n "$DEV" ] && hdiutil detach "$DEV" -quiet >/dev/null 2>&1
  DEV=""
}
trap 'release; rm -rf "$WORK"' EXIT

echo "$CYCLES cycles: attach $IMAGE, open it through the app, write $FILES files at once"
[ "$SETTLE" != "0" ] && echo "  waiting $SETTLE s after the open before writing"

stale=0; short=0; clean=0; failed=0
for c in $(seq 1 "$CYCLES"); do
  DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${DEV:-}" ] || { echo "  cycle $c: would not attach"; failed=$((failed+1)); continue; }

  if ! timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1; then
    echo "  cycle $c: did not open: $(tail -1 "$WORK/open.log")"
    failed=$((failed+1)); release; continue
  fi
  point="$(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | head -1)"
  [ -n "${point:-}" ] || { echo "  cycle $c: opened and nothing is served"; failed=$((failed+1)); release; continue; }

  [ "$SETTLE" != "0" ] && sleep "$SETTLE"

  dest="$point/first-write"
  ditto "$SRC" "$dest" > "$WORK/ditto.log" 2>&1
  rc=$?
  (cd "$dest" && find . -type f -exec shasum -a 256 {} \; | sort) \
    > "$WORK/after.sums" 2>"$WORK/after.err"

  got=$(/usr/bin/grep -c . < "$WORK/after.sums")
  if /usr/bin/grep -qi 'stale' "$WORK/after.err" "$WORK/ditto.log" 2>/dev/null; then
    stale=$((stale+1))
    echo "  cycle $c: STALE  $(head -1 "$WORK/after.err" | cut -c1-100)"
  elif [ "$rc" -ne 0 ]; then
    failed=$((failed+1))
    echo "  cycle $c: the copy failed: $(tail -1 "$WORK/ditto.log" | cut -c1-100)"
  elif diff -q "$WORK/before.sums" "$WORK/after.sums" >/dev/null 2>&1; then
    clean=$((clean+1))
    # Said out loud. This printed only when something went wrong, so a run that
    # was working looked exactly like a run that had hung, and five minutes of
    # a silent log were spent deciding which.
    printf '  cycle %2d: clean\n' "$c"
  else
    short=$((short+1))
    echo "  cycle $c: $got of $FILES read back, $(head -1 "$WORK/after.err" | cut -c1-80)"
  fi
  rm -rf "$dest" >/dev/null 2>&1
  release
done

echo
echo "RESULT: $clean clean, $stale stale handles, $short short, $failed did not run"
[ "$stale" -eq 0 ] && [ "$short" -eq 0 ] && [ "$failed" -eq 0 ]
