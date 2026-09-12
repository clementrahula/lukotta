#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Opening a drive with a saved key never puts a keychain prompt in front of anybody.
#   ./scripts/no-keychain-prompt.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: no-keychain-prompt.sh <device>}"
DEV="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$DEV" ] || { echo "no dev build at $DEV"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
served() { mount | grep -F "$HOST:" | grep -q nobrowse; }
settle() { local t0; t0=$(date +%s); while [ "$(( $(date +%s) - t0 ))" -lt 60 ]; do served || return 0; sleep 1; done; return 1; }
# What macOS puts on screen to ask for a keychain, and the agent behind it.
prompts() { pgrep -fc "SecurityAgent|loginwindow.*SecurityAgent|CFUserNotification" 2>/dev/null || true; }

pkill -x "Lukotta Dev"; sleep 2
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle || { echo "the drive would not close before the check"; exit 1; }

before="$(prompts)"
"$DEV" --drive open="$DEVICE" > "$WORK/open.log" 2>&1 &
opening=$!
worst=0
while kill -0 "$opening" 2>/dev/null; do
  now="$(prompts)"
  [ "$now" -gt "$worst" ] && worst="$now"
  sleep 0.3
done
wait "$opening"; rc=$?
after="$(prompts)"
used="$(grep -c "using the key saved under" "$WORK/open.log")"
opened=no
served && opened=yes
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle >/dev/null

echo "keychain prompts: $before before, $worst at most while opening, $after after; saved key used $used time(s); opened: $opened"
[ "$rc" = 0 ] && [ "$opened" = yes ] && [ "$used" -ge 1 ] && [ "$worst" -le "$before" ]
