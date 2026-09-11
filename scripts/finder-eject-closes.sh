#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive opened in the dev build's window and ejected in Finder: the window goes back to the list and the row opens again.
#   ./scripts/finder-eject-closes.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: finder-eject-closes.sh <device>}"
APP="/Applications/Lukotta Dev.app"
BUNDLE="com.lukotta.dev"
HOST="$(basename "$DEVICE").local"
[ -d "$APP" ] || { echo "no dev build at $APP"; exit 2; }
WORK="$(mktemp -d)"
trap 'pkill -x "Lukotta Dev"; rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ax-press" "$(dirname "$0")/ax-press.swift" 2>/dev/null || { echo "ax-press did not build"; exit 2; }
ax() { "$WORK/ax-press" "$BUNDLE" "$@" | tail -n 1; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }

pkill -x "Lukotta Dev"; sleep 2
open -a "$APP"; sleep 6
[ "$(ax press "drive $DEVICE" 20)" = pressed ] || { echo "no row for $DEVICE"; exit 1; }
[ "$(ax press unlock 20)" = pressed ] || { echo "no Unlock button"; exit 1; }
point=""
for _ in $(seq 1 60); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
[ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }
[ "$(ax shows "Show in Finder" 30)" = shown ] || { echo "the window never showed the open drive"; exit 1; }

osascript -e 'on run argv' -e 'tell application "Finder" to eject (POSIX file (item 1 of argv) as alias)' -e 'end run' "$point" >/dev/null 2>&1 \
  || diskutil unmount "$point" >/dev/null
t0=$(date +%s)
back=""
for _ in $(seq 1 30); do
  sleep 1
  if [ "$(ax shows "Show in Finder" 0.3)" != shown ] && [ "$(ax shows Rescan 0.3)" = shown ]; then
    back="$(( $(date +%s) - t0 ))"; break
  fi
done
row="$(ax press "drive $DEVICE" 5)"
echo "Finder eject of '$point': list back after ${back:-never} s, row $row, mounts left $(mount | grep -c "$HOST")"
[ -n "$back" ] && [ "$row" = pressed ]
