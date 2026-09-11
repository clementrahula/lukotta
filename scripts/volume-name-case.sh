#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Finder shows a volume opened by the dev build under the drive's own label, case and all, at a clean path.
#   ./scripts/volume-name-case.sh <device>
set -uo pipefail
DEVICE="${1:?usage: volume-name-case.sh <device>}"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$APP" ] || { echo "no dev build at $APP"; exit 2; }

finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -1; }
label() { mount | grep -F "$HOST:/" | head -1 | sed -E 's/^[^:]*:([^ ]*) on .*/\1/' | xargs basename; }

"$APP" --drive open="$DEVICE" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
point=""
for _ in $(seq 1 30); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
want="$(label)"
shown=""
[ -n "$point" ] && shown="$(osascript -e 'on run argv' -e 'tell application "Finder" to get displayed name of (POSIX file (item 1 of argv) as alias)' -e 'end run' "$point" 2>/dev/null)"
"$APP" --drive eject="$DEVICE" >/dev/null 2>&1

echo "label '$want', Finder shows '${shown:-nothing}' at '${point:-nowhere}'"
[ -n "$want" ] && [ "$shown" = "$want" ] && [ "$point" = "/Volumes/$want" ]
