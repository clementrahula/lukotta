#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A second drive opens while a first one is open.
#
# WHAT IT GUARDS
#
# The engine keeps one flock for the whole machine. A mount takes it shared, so
# any number of drives can be served at once -- and before mounting, the engine
# compares the vmproxy inside the unpacked guest against the copy in the app
# bundle and, where they differ, upgrades that lock to exclusive to replace it.
# An upgrade cannot be taken while another drive holds the shared lock, so with
# a guest that does not match the bundle the second drive fails outright:
# "another instance is already running", and one of twelve is served.
#
# A user would meet it by updating the app, opening a drive, opening a second
# one, and being told the app is already running -- for ever, on every launch.
# It has happened once, on 2026-09-04, because the app's guest refresh had never
# worked and the version it compares was upstream's rather than this project's.
#
# WHY IT IS ITS OWN CHECK RATHER THAN PART OF THE TWELVE
#
# twelve-under-pressure.sh catches it, and takes forty minutes and eight
# gigabytes of ballast to do so. Two drives take half a minute and fail for the
# same reason, so this is the one that can run on every build.
#
#   ./scripts/two-at-once.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
A="${A:-$OUT/crowd/drive1.img}"
B="${B:-$OUT/crowd/drive4.img}"

[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ -f "$A" ] && [ -f "$B" ] || { echo "error: need $A and $B" >&2; exit 2; }
# grep -c, not grep -q: under pipefail a -q match exits at once, strings dies of
# SIGPIPE, and the check refuses every bundle that is fine.
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

WORK="$(mktemp -d)"
DEVS=""
clean_up() {
  for p in $(mount | /usr/bin/grep -F '.local:/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  for d in $DEVS; do hdiutil detach "$d" -force -quiet >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap clean_up EXIT
for p in $(mount | /usr/bin/grep -F '.local:/mnt/' | awk '{print $3}'); do
  umount -f "$p" >/dev/null 2>&1
done

open_one() {
  local img="$1" n="$2" dev
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$img" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${dev:-}" ] || { echo "  $n: would not attach" >&2; return 1; }
  DEVS="$DEVS $dev"
  local start took
  start="$(date +%s)"
  timeout 900 "$APP" --drive open="$dev" > "$WORK/open$n.log" 2>&1
  took=$(( $(date +%s) - start ))
  if mount | /usr/bin/grep -qF "$(basename "$dev").local:"; then
    echo "  $n: served in ${took}s"
    return 0
  fi
  echo "  $n: not served after ${took}s -- $(tail -2 "$WORK/open$n.log" | tr '\n' ' ')" >&2
  return 1
}

echo "opening two drives, one after the other, both left open"
first=0; second=0
open_one "$A" 1 && first=1
open_one "$B" 2 && second=1
served="$(mount | /usr/bin/grep -cF '.local:/mnt/')"

echo
if [ "$first" = 1 ] && [ "$second" = 1 ] && [ "$served" -ge 2 ]; then
  echo "RESULT: both drives are open at the same time"
  exit 0
fi
echo "RESULT: $served of 2 served -- a drive cannot be opened while another is" >&2
exit 1
