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
name="$(basename "$point")"
[ "$(ax shows "Show in Finder" 60)" = shown ] || { echo "the window never showed the drive open"; exit 1; }

osascript -e 'tell application "Lukotta Dev" to quit' >/dev/null 2>&1 &
lq="$(printf '\342\200\234')"; rq="$(printf '\342\200\235')"
asked="$(ax shows "Quit and leave ${lq}${name}${rq} open?" 15)"
[ "$(ax title "Eject and Quit" 10)" = pressed ] || { echo "no Eject and Quit in the question"; exit 1; }
ejecting=""
for _ in $(seq 1 80); do
  [ "$(ax shows "Ejecting $name" 0.1)" = shown ] && { ejecting=shown; break; }
  pgrep -x "Lukotta Dev" >/dev/null || break
done
for _ in $(seq 1 60); do pgrep -x "Lukotta Dev" >/dev/null || break; sleep 0.5; done
left="$(mount | grep -c "$HOST")"
echo "question names '$name': $asked; 'Ejecting $name' shown: ${ejecting:-no}; mounts left: $left"
[ "$asked" = shown ] && [ "$ejecting" = shown ] && [ "$left" = 0 ]
