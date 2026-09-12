#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Opening a drive in the dev build's window shows progress within a second of Unlock, and a countdown until the drive is open.
#   ./scripts/open-shows-progress.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: open-shows-progress.sh <device>}"
APP="/Applications/Lukotta Dev.app"
BUNDLE="com.lukotta.dev"
HOST="$(basename "$DEVICE").local"
[ -d "$APP" ] || { echo "no dev build at $APP"; exit 2; }
WORK="$(mktemp -d)"
trap '"$APP/Contents/MacOS/Lukotta Dev" --drive eject="$DEVICE" >/dev/null 2>&1; pkill -x "Lukotta Dev"; rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ax-press" "$(dirname "$0")/ax-press.swift" 2>/dev/null || { echo "ax-press did not build"; exit 2; }
ax() { "$WORK/ax-press" "$BUNDLE" "$@" | tail -n 1; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN {printf "%.1f", b - a}'; }

pkill -x "Lukotta Dev"; sleep 2
open -a "$APP"; sleep 6
[ "$(ax press "drive $DEVICE" 20)" = pressed ] || { echo "no row for $DEVICE"; exit 1; }
[ "$(ax press unlock 20)" = pressed ] || { echo "no Unlock button"; exit 1; }
t0="$(now)"
first=""; gaps=0; miss=0; samples=0; open_at=""
for _ in $(seq 1 240); do
  if mount | grep -F "@$HOST/" | grep -q afpfs && [ "$(ax shows "Opening" 0.2)" != shown ]; then
    open_at="$(since "$t0")"; break
  fi
  samples=$((samples + 1))
  # Every estimate the window can show while it works: the countdown, the one that
  # owns up to taking longer, the one before a first open has anything to go on, and
  # the one for a volume being repaired. Any of them is the person being told where
  # the open has got to; none of them is a blank screen.
  if [ "$(ax shows "left" 0.2)" = shown ] || [ "$(ax shows "so far" 0.2)" = shown ] \
    || [ "$(ax shows "under a minute" 0.2)" = shown ] \
    || [ "$(ax shows "few minutes" 0.2)" = shown ]; then
    [ -n "$first" ] || first="$(since "$t0")"
    miss=0
  elif [ -n "$first" ]; then
    # Consecutive misses only. One sample of an accessibility tree caught mid-redraw is
    # not a screen anybody saw go blank; two in a row is a third of a second or more.
    miss=$((miss + 1))
    [ "$miss" -gt "$gaps" ] && gaps="$miss"
  fi
  sleep 0.3
done
echo "progress first seen ${first:-never} s after Unlock; longest run without it $gaps of $samples samples; open after ${open_at:-never} s"
[ -n "$first" ] && [ -n "$open_at" ] && [ "$gaps" -lt 2 ] \
  && awk -v f="$first" 'BEGIN {exit !(f <= 1.0)}'
