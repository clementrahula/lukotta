#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Every setting of an app thrown away, and the saved key still opens the drive with nothing typed.
#   ./scripts/key-survives-wiped-settings.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: key-survives-wiped-settings.sh <device>}"
DEV="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
DOMAIN="com.lukotta.dev"
HOST="$(basename "$DEVICE").local"
[ -x "$DEV" ] || { echo "no dev build at $DEV"; exit 2; }
served() { mount | grep -F "$HOST:" | grep -q nobrowse; }
settle() { local t0; t0=$(date +%s); while [ "$(( $(date +%s) - t0 ))" -lt 60 ]; do served || return 0; sleep 1; done; return 1; }

pkill -x "Lukotta Dev"; sleep 2
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle || { echo "the drive would not close before the settings were wiped"; exit 1; }

# Everything this app keeps for itself. The key is not in here -- that is the point --
# and neither is what every Lukotta app remembers about drives, which lives in a file
# of its own that no app owns.
before="$(defaults read "$DOMAIN" 2>/dev/null | wc -l | tr -d ' ')"
defaults delete "$DOMAIN" >/dev/null 2>&1
after="$(defaults read "$DOMAIN" 2>/dev/null | wc -l | tr -d ' ')"
echo "settings wiped: $before lines before, $after after"

out="$("$DEV" --drive open="$DEVICE" 2>&1)"; rc=$?
used="$(printf '%s\n' "$out" | grep -c "using the key saved under")"
opened=no
served && opened=yes
"$DEV" --drive eject="$DEVICE" >/dev/null 2>&1
settle >/dev/null
echo "with nothing of its own left, the app found the key $used time(s) and opened the drive: $opened"
[ "$rc" = 0 ] && [ "$used" -ge 1 ] && [ "$opened" = yes ]
