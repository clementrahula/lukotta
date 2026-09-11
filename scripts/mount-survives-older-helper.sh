#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive opened by the dev build reaches Finder and stays there, every time, while other Lukotta helpers run.
#   ./scripts/mount-survives-older-helper.sh <device> [times]
#   ./scripts/mount-survives-older-helper.sh /dev/disk5 10
set -uo pipefail
DEVICE="${1:?usage: mount-survives-older-helper.sh <device> [times]}"
TIMES="${2:-10}"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$APP" ] || { echo "no dev build at $APP"; exit 2; }

others="$(pgrep -fl 'Lukotta(Beta|V2)?Helper|com\.lukotta\.helper' | sort -u | paste -sd';' -)"
echo "other helpers running: ${others:-none}"

finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -1; }
engine_mount() { mount | grep -F "$HOST:" | head -1; }

failures=0
for i in $(seq 1 "$TIMES"); do
  t0=$(date +%s)
  out="$("$APP" --drive open="$DEVICE" 2>&1)"; rc=$?
  point=""
  for _ in $(seq 1 30); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
  held=0
  if [ -n "$point" ]; then
    sleep 10
    [ -n "$(finder_volume)" ] && [ -n "$(engine_mount)" ] && held=1
  fi
  if [ "$rc" = 0 ] && [ "$held" = 1 ]; then
    echo "open $i: in Finder at $point after $(( $(date +%s) - t0 - 10 )) s, still there 10 s later"
  else
    echo "open $i: FAILED (status $rc, Finder volume '${point:-none}', held $held)"
    printf '%s\n' "$out" | tail -3 | sed 's/^/    /'
    failures=$((failures + 1))
  fi
  "$APP" --drive eject="$DEVICE" >/dev/null 2>&1
  for _ in $(seq 1 30); do [ -z "$(engine_mount)" ] && [ -z "$(finder_volume)" ] && break; sleep 1; done
done
echo "$((TIMES - failures)) of $TIMES opens reached Finder and held"
[ "$failures" -eq 0 ]
