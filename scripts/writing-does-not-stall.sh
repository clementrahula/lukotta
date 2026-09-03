#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Item 1, as a pass or a fail: no request goes unanswered long enough to be seen.
#
# WHAT THE THRESHOLD IS AND WHY IT IS NOT ARBITRARY
#
# macOS tells somebody the server has stopped responding when a request to an
# NFS mount goes unanswered for five seconds. That dialog is the fault -- not
# slowness. A copy that takes twice as long and never crosses five seconds is a
# pass; a copy that finishes quickly with one request at 5.1s is the failure
# this whole item is about.
#
# flush-latency.sh measures the distribution and deliberately renders no verdict
# -- its own note says so, and it is right to: a worst case of four seconds is
# one bad moment away from the dialog and reads as success. But a claim with no
# pass and no fail cannot be checked, and an unchecked claim quietly becomes a
# remembered one. So the measuring stays verdict-free and the judgement lives
# here, where the threshold can be stated once and argued with.
#
# It opens the drive the way a person does, through the app, because the
# durability options and the NFS parameters that decide this are chosen by the
# app and not by a hand-written mount.
#
#   ./scripts/writing-does-not-stall.sh
#   MB=800 ./scripts/writing-does-not-stall.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-ntfs-vectors.img}"
MB="${MB:-400}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/$IMAGE"

[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

WORK="$(mktemp -d)"
DEV=""
release_drives() {
  for p in $(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  for d in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}'); do
    hdiutil detach "$d" -force -quiet >/dev/null 2>&1
  done
  DEV=""
}
trap 'release_drives; rm -rf "$WORK"' EXIT
release_drives

DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "error: $IMAGE would not attach" >&2; exit 2; }
timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "error: did not open: $(tail -1 "$WORK/open.log")" >&2; exit 2; }
POINT="$(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "error: opened and nothing is served" >&2; exit 2; }
echo "opened $POINT through the app"

bash scripts/flush-latency.sh "$POINT" "$MB" 1 2>&1 | tee "$WORK/latency.log"

over=$(/usr/bin/grep -o 'over 5s (the threshold): [0-9]*' "$WORK/latency.log" \
  | awk '{print $NF}' | head -1)
worst=$(/usr/bin/grep -o 'worst [0-9.]*s' "$WORK/latency.log" | awk '{print $2}' | head -1)

echo
if [ -z "${over:-}" ]; then
  echo "RESULT: the measurement produced no reading to judge" >&2
  exit 1
fi
if [ "$over" -eq 0 ]; then
  echo "RESULT: nothing went unanswered for five seconds; worst was ${worst:-unknown}"
  exit 0
fi
echo "RESULT: $over request(s) unanswered past five seconds; worst ${worst:-unknown}" >&2
echo "        that is the dialog a person is shown mid-copy" >&2
exit 1
