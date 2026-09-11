#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A key saved once opens the drive from every Lukotta app: the dev build through its own route, the beta through its window, nothing typed.
#   ./scripts/key-found-by-every-app.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: key-found-by-every-app.sh <device>}"
HOST="$(basename "$DEVICE").local"
DEV="/Applications/Lukotta Dev.app"
BETA="/Applications/Lukotta Beta.app"
[ -d "$DEV" ] || { echo "no dev build at $DEV"; exit 2; }
WORK="$(mktemp -d)"
trap 'pkill -x "Lukotta Beta"; pkill -x "Lukotta Dev"; rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ax-press" "$(dirname "$0")/ax-press.swift" 2>/dev/null || { echo "ax-press did not build"; exit 2; }
served() { mount | grep -F "$HOST:" | grep -q nobrowse; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }
wait_for() { local t0; t0=$(date +%s); while [ "$(( $(date +%s) - t0 ))" -lt "$2" ]; do $1 && return 0; sleep 1; done; return 1; }
gone() { ! served; }
opened=0

out="$("$DEV/Contents/MacOS/Lukotta Dev" --drive open="$DEVICE" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "using the key saved under"; then
  echo "Lukotta Dev: opened with the saved key, nothing typed"
  opened=$((opened + 1))
else
  echo "Lukotta Dev: did not use a saved key (status $rc)"
fi
"$DEV/Contents/MacOS/Lukotta Dev" --drive eject="$DEVICE" >/dev/null 2>&1
wait_for gone 30 || echo "Lukotta Dev: the drive is still served after eject"

if [ -d "$BETA" ]; then
  ax() { "$WORK/ax-press" com.lukotta.beta "$@" | tail -n 1; }
  pkill -x "Lukotta Beta"; sleep 2
  open -a "$BETA"; sleep 6
  [ "$(ax press "drive $DEVICE" 30)" = pressed ] || echo "Lukotta Beta: no row for $DEVICE"
  [ "$(ax shows "Unlock uses it directly" 15)" = shown ] \
    || echo "Lukotta Beta: no saved key offered for $DEVICE"
  [ "$(ax press unlock 20)" = pressed ] || echo "Lukotta Beta: no Unlock button"
  point=""
  for _ in $(seq 1 90); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
  if [ -n "$point" ]; then
    echo "Lukotta Beta: opened with the saved key at $point, nothing typed"
    opened=$((opened + 1))
    # Ejected once the window says the drive is open: ejecting mid-open leaves the engine settling.
    [ "$(ax shows "Show in Finder" 60)" = shown ] || echo "Lukotta Beta: the window never showed it open"
    said="$(osascript -e 'on run argv' -e 'tell application "Finder" to eject (POSIX file (item 1 of argv) as alias)' -e 'end run' "$point" 2>&1 >/dev/null)"
    [ -z "$said" ] || echo "Lukotta Beta: Finder refused to eject it: $said"
    wait_for gone 90 || echo "Lukotta Beta: the drive is still served 90 s after Finder ejected it"
  else
    echo "Lukotta Beta: the drive did not reach Finder"
  fi
  pkill -x "Lukotta Beta"
fi

echo "$opened app(s) opened $DEVICE with the key nobody typed"
[ "$opened" -ge 2 ]
