#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Quitting the dev build with a drive open names the drive, as Finder names it, in the question and while it ejects.
#   ./scripts/quit-names-drive.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: quit-names-drive.sh <device>}"
APP="/Applications/Lukotta Dev.app"
BUNDLE="com.lukotta.dev"
HOST="$(basename "$DEVICE").local"
[ -d "$APP" ] || { echo "no dev build at $APP"; exit 2; }
WORK="$(mktemp -d)"
# Whatever happens, the drive is closed again: a run that stops half way must not leave
# the next one looking at a drive that is already open and reporting there is no row.
trap 'pkill -x "Lukotta Dev"; "$APP/Contents/MacOS/Lukotta Dev" --drive eject="$DEVICE" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
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
name="$(basename "$point")"
# Both, before quitting: the window saying the drive is open, and Finder's volume actually
# there. Quitting between the two is quitting mid-open -- the app has no open drive to ask
# about, goes straight out, and leaves the engine's own mount behind.
[ "$(ax shows "Show in Finder" 60)" = shown ] || { echo "the window never showed the drive open"; exit 1; }
settled=""
for _ in $(seq 1 30); do
  [ -n "$(finder_volume)" ] && [ "$(ax shows "Show in Finder" 1)" = shown ] && { settled=yes; break; }
  sleep 1
done
[ "$settled" = yes ] || { echo "the drive never settled open: volume '$(finder_volume)'"; exit 1; }

osascript -e 'tell application "Lukotta Dev" to quit' >/dev/null 2>&1 &
lq="$(printf '\342\200\234')"; rq="$(printf '\342\200\235')"
asked="$(ax shows "Quit and leave ${lq}${name}${rq} open?" 15)"
if [ "$(ax title "Eject and Quit" 10)" != pressed ]; then
  # What was on screen instead, so the next failure explains itself rather than repeating.
  echo "no Eject and Quit in the question; the app showed:"
  osascript -e 'tell application "System Events" to tell process "Lukotta Dev"' \
    -e 'set out to ""' \
    -e 'repeat with w in windows' \
    -e 'set out to out & "window: " & (name of w) & " buttons: " & (name of every button of w) & linefeed' \
    -e 'end repeat' -e 'return out' -e 'end tell' 2>&1 | sed 's/^/  /' | head -n 6
  echo "  still running: $(pgrep -x "Lukotta Dev" | wc -l | tr -d ' '); mounts: $(mount | grep -c "$HOST")"
  exit 1
fi
ejecting=""
for _ in $(seq 1 80); do
  [ "$(ax shows "Ejecting $name" 0.1)" = shown ] && { ejecting=shown; break; }
  pgrep -x "Lukotta Dev" >/dev/null || break
done
for _ in $(seq 1 60); do pgrep -x "Lukotta Dev" >/dev/null || break; sleep 0.5; done
left="$(mount | grep -c "$HOST")"
echo "question names '$name': $asked; 'Ejecting $name' shown: ${ejecting:-no}; mounts left: $left"
[ "$asked" = shown ] && [ "$ejecting" = shown ] && [ "$left" = 0 ]
