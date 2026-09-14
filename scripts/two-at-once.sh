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
# gigabytes of ballast to do so. Two drives take a minute and fail for the same
# reason.
#
# Real drives only. An image is backed by a file, and the host's cache covers for
# what the guest does not do.
#
#   ./scripts/two-at-once.sh /dev/diskNsM /dev/diskPsQ
set -uo pipefail

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"

A="${1:?usage: two-at-once.sh /dev/diskNsM /dev/diskPsQ}"
B="${2:?usage: two-at-once.sh /dev/diskNsM /dev/diskPsQ}"
APP_BUNDLE="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"

[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
# grep -c, not grep -q: under pipefail a -q match exits at once, strings dies of
# SIGPIPE, and the check refuses every bundle that is fine.
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }
for dev in "$A" "$B"; do
  [ -b "$dev" ] || { echo "error: $dev is not a block device" >&2; exit 2; }
  [ "$(mount | /usr/bin/grep -cF "$(basename "$dev").local:")" = 0 ] \
    || { echo "error: $dev is open; eject it first" >&2; exit 2; }
done
[ "$A" != "$B" ] || { echo "error: two different drives" >&2; exit 2; }

WORK="$(mktemp -d)"
OPENED=""
# Only what this run opened is closed, through the app that opened it.
clean_up() {
  for dev in $OPENED; do "$APP" --drive eject="$dev" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap clean_up EXIT

open_one() {
  local dev="$1" n="$2" start took
  start="$(date +%s)"
  timeout 900 "$APP" --drive open="$dev" > "$WORK/open$n.log" 2>&1
  took=$(( $(date +%s) - start ))
  OPENED="$OPENED $dev"
  if [ "$(mount | /usr/bin/grep -cF "$(basename "$dev").local:")" -gt 0 ]; then
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

echo
if [ "$first" = 1 ] && [ "$second" = 1 ]; then
  echo "RESULT: both drives are open at the same time"
  exit 0
fi
echo "RESULT: a drive cannot be opened while another is" >&2
exit 1
