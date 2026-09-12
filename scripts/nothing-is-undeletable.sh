#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Nothing on a Lukotta drive arrives without its write bit, and a folder deletes in Finder with no dialog.
#   ./scripts/nothing-is-undeletable.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: nothing-is-undeletable.sh <device>}"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$APP" ] || { echo "no dev build at $APP"; exit 2; }
# Built without devtools the app has no --drive at all: it raises a window and
# waits for events, which reads as a hang and says nothing.
# Counted, not `grep -q`: under pipefail a quiet grep exits on the first match
# while strings is still writing, and the pipeline fails on success.
[ "$(strings -a "$APP" 2>/dev/null | grep -c -- "--drive")" -gt 0 ] \
  || { echo "$APP has no --drive; rebuild with LUKOTTA_DEVTOOLS=1"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/windows.swift" <<'EOF'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(all.filter { ($0[kCGWindowOwnerName as String] as? String) == "Finder"
    && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
EOF
swiftc -O -o "$WORK/finder-windows" "$WORK/windows.swift" 2>/dev/null || { echo "window counter did not build"; exit 2; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }

# A BitLocker drive that needs checking runs ntfsck over the whole MFT before it
# mounts, which is minutes on a big one. The wait matches the prover's own 240 s,
# and the timeout is so a stall ends the run rather than hanging it.
timeout 900 "$APP" --drive open="$DEVICE" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
point=""
for _ in $(seq 1 240); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
[ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }
failed=0

# A drive written by Windows carries folders marked read-only there, and the driver puts
# that mark in the mode. Finder goes by the mode, so such a folder cannot be dropped in
# the bin at all -- it answers that the item is in use, which is neither true nor useful.
# Three of them sat on the owner's drive, taking new files underneath the whole time.
stuck="$(find "$point" -maxdepth 2 -type d ! -perm -u+w ! -name '.Trashes' 2>/dev/null | head -n 5)"
if [ -n "$stuck" ]; then
  echo "folders arrived with no write bit, which is what Finder refuses to delete:"
  printf '%s\n' "$stuck" | sed 's/^/  /'
  failed=1
else
  echo "every folder on the drive arrived writable"
fi

before="$("$WORK/finder-windows")"
target="$point/undeletable-$$"
if mkdir -p "$target/inner" && : > "$target/inner/file.bin"; then
  err="$(osascript -e 'on run argv' -e 'tell application "Finder"' -e 'with timeout of 120 seconds' \
    -e 'delete (POSIX file (item 1 of argv) as alias)' -e 'end timeout' -e 'end tell' -e 'end run' "$target" 2>&1 >/dev/null)"
  dialogs=$(( $("$WORK/finder-windows") - before ))
  echo "Finder delete: ${err:-no error}; $dialogs new Finder windows"
  if [ -n "$err" ] || [ -e "$target" ] || [ "$dialogs" -gt 0 ]; then failed=1; fi
else
  echo "could not make a folder on the drive"
  failed=1
fi

chmod -R 700 "$target" 2>/dev/null
rm -rf "$target" "$point/.Trashes/$(id -u)/undeletable-$$"*
"$APP" --drive eject="$DEVICE" >/dev/null 2>&1
[ "$failed" = 0 ]
