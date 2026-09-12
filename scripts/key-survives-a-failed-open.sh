#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# An open that fails never costs the saved key: the drive opens again with it straight after.
#   ./scripts/key-survives-a-failed-open.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: key-survives-a-failed-open.sh <device>}"
DEV="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$DEV" ] || { echo "no dev build at $DEV"; exit 2; }
served() { mount | grep -F "$HOST:" | grep -q nobrowse; }
settle() { local t0; t0=$(date +%s); while [ "$(( $(date +%s) - t0 ))" -lt 60 ]; do served || return 0; sleep 1; done; return 1; }

"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle || { echo "the drive was already open and would not close"; exit 1; }

# Not a password anybody uses: a string that cannot unlock anything, to make the attempt fail.
"$DEV" --drive open="$DEVICE" passphrase=this-cannot-unlock-anything >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && served; then
  echo "the drive opened with a passphrase that cannot be right; this check proves nothing"
  "$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
  exit 1
fi
echo "the open failed, as it had to (status $rc)"
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle || echo "something is still served after the failed attempt"

again="$("$DEV" --drive open="$DEVICE" 2>&1)"; rc=$?
used="$(printf '%s\n' "$again" | grep -c "using the key saved under")"
opened=no
served && opened=yes
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle >/dev/null
echo "after the failure the saved key is still there: used $used time(s), drive opened: $opened"
[ "$rc" = 0 ] && [ "$used" -ge 1 ] && [ "$opened" = yes ]
