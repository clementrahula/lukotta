#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive opened once stays known: every Lukotta app shows it by name while it is locked, from what they all remember.
#   ./scripts/drive-known-by-every-app.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: drive-known-by-every-app.sh <device>}"
DEV="/Applications/Lukotta Dev.app"
BETA="/Applications/Lukotta Beta.app"
HOST="$(basename "$DEVICE").local"
MEMORY="$HOME/Library/Application Support/Lukotta/memory.json"
[ -d "$DEV" ] || { echo "no dev build at $DEV"; exit 2; }
WORK="$(mktemp -d)"
trap 'pkill -x "Lukotta Dev"; pkill -x "Lukotta Beta"; rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ax-press" "$(dirname "$0")/ax-press.swift" 2>/dev/null || { echo "ax-press did not build"; exit 2; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }

# What the drive is called, taken from the drive itself: open it once and read the volume Finder shows.
"$DEV/Contents/MacOS/Lukotta Dev" --drive open="$DEVICE" >/dev/null 2>&1
point=""
for _ in $(seq 1 90); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
[ -n "$point" ] || { echo "the drive did not open, so there is no name to remember"; exit 1; }
name="$(basename "$point")"
"$DEV/Contents/MacOS/Lukotta Dev" --drive eject="$DEVICE" >/dev/null 2>&1
for _ in $(seq 1 60); do mount | grep -q "$HOST" || break; sleep 1; done
echo "the drive opened as '$name' and is locked again"

held="$(/usr/bin/python3 -c "
import json, sys
memory = json.load(open(sys.argv[1]))
print('yes' if sys.argv[2] in memory.get('names', {}).values() else 'no')
" "$MEMORY" "$name" 2>/dev/null)"
echo "the shared memory every app reads holds that name: ${held:-no}"

shown=0
for app in "$DEV" "$BETA"; do
  [ -d "$app" ] || continue
  label="$(basename "$app" .app)"
  id="com.lukotta.dev"
  [ "$label" = "Lukotta Beta" ] && id="com.lukotta.beta"
  pkill -x "$label"; sleep 2
  open -a "$app"; sleep 7
  if [ "$("$WORK/ax-press" "$id" shows "$name" 20 | tail -n 1)" = shown ]; then
    echo "$label: shows the locked drive as '$name'"
    shown=$((shown + 1))
  else
    echo "$label: does not show '$name'"
  fi
  pkill -x "$label"
done
echo "$shown app(s) name the locked drive from what they all remember"
[ "$held" = yes ] && [ "$shown" -ge 2 ]
