#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The one window nobody may ever see.
#
#   ./scripts/never-the-interrupted-window.sh
#
# macOS puts up "Server connections interrupted", naming the drive and offering
# Disconnect All, when an NFS mount's server stops answering. It reached the
# owner on 2026-09-05, from mounts whose engine had been killed and which
# nothing then took away.
#
# There is no mount option that suppresses it. Asked of mount_nfs(5) directly:
# `mutejukebox` keeps a file system out of that list only for jukebox errors --
# "NFS requests repeatedly get jukebox errors ... prevent the file system from
# being included in the list of unresponsive file systems that would be included
# in a dialog presented to the user" -- and a server that has gone is not that.
# `deadtimeout` only decides how long after being reported unresponsive macOS
# force-unmounts it, which is later still.
#
# So the only way the window never appears is that a mount is never left
# unresponsive long enough for macOS to say so. Two ways a mount can go quiet:
#
#   the engine dies          nothing to answer, ever. This is what is checked
#                            here: the app must take the mount away itself,
#                            quickly, before macOS begins to reckon.
#   the drive goes slow      the engine is alive and answering; that is the
#                            stall work, items 1 to 3, and it is measured by
#                            writing-does-not-stall.sh.
#
# WHAT IS ASSERTED
#
# A drive is opened through the app, its engine is killed the way a crash would
# kill it, and the mount must be gone on its own -- nobody ejecting it, nobody
# unmounting it -- inside the window. The bound is generous against macOS and
# tight against the app: the sweep looks every 30 seconds and the probe inside
# it spends about a minute deciding a mount is dead rather than merely slow, so
# ninety seconds is the design and 180 is the bar.
#
# And the log is asked whether macOS said anything about it, over this run's own
# window, because the point is not that the mount went but that nobody was told.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-plain-ext4.img}"
BOUND="${BOUND:-180}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/$IMAGE"

[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

DEV=""
cleanup() {
  [ -n "$DEV" ] && timeout 200 "$APP" --drive eject="$DEV" >/dev/null 2>&1
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force -quiet >/dev/null 2>&1
}
trap cleanup EXIT

# Nothing served before this starts, or the count below is somebody else's.
if [ "$(mount | /usr/bin/grep -c ':/mnt/' || true)" -gt 0 ]; then
  echo "error: something is already served; not starting" >&2
  mount | /usr/bin/grep ':/mnt/' | sed 's/^/       /' >&2
  exit 2
fi

DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "error: $IMAGE would not attach" >&2; exit 2; }

# With the app running, which is the way somebody uses this.
#
# The sweep lives in the app and in the helper. The app's is measured and works:
# a mount whose engine was killed went in about twenty seconds. The helper's does
# not -- with the app quit, the same mount was still there after three hundred
# seconds -- and that gap is written down in MEASUREMENTS.md rather than hidden
# by only ever testing the route that works. What this asserts is the guarantee
# that holds today.
/usr/bin/open -a "$APP_BUNDLE" >/dev/null 2>&1
sleep 5

STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
timeout 300 "$APP" --drive open="$DEV" > /tmp/never-window-open.log 2>&1 \
  || { echo "error: the drive did not open" >&2; tail -3 /tmp/never-window-open.log >&2; exit 1; }
POINT="$(mount | /usr/bin/grep -F "$(basename "$DEV").local:" | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "error: opened and nothing is served" >&2; exit 1; }
echo "opened $POINT"

# Killed the way a crash kills it: no chance to unmount anything on the way out.
echo "killing the engine that serves it"
/usr/bin/pkill -9 -f 'anylinuxfs|krun' >/dev/null 2>&1
sleep 2
[ "$(mount | /usr/bin/grep -c -F "$POINT" || true)" -gt 0 ] || {
  echo "error: the mount went when the engine did, so this measures nothing" >&2
  exit 1; }
echo "  the mount is still in the table, with nothing behind it"

# Nobody ejects it. The app has to notice.
waited=0
while [ "$waited" -lt "$BOUND" ]; do
  [ "$(mount | /usr/bin/grep -c -F "$POINT" || true)" -eq 0 ] && break
  sleep 5
  waited=$((waited + 5))
done
left="$(mount | /usr/bin/grep -c -F "$POINT" || true)"

# And whether macOS said anything to anybody while that happened.
# Neither of the two ways this counted itself.
#
# `log show` prints "Filtering the log data using ..." with the predicate in it,
# and the predicate contains the words being counted. Excluding that line was
# not enough: `log` also logs its own invocation, arguments and all, so the
# query writes a line containing its own predicate into the very log it is
# reading. Both were counted, and this reported that macOS had complained on
# every run -- including runs where nothing of the sort had happened.
#
# So the filter line goes, and so does anything the `log` process itself said.
said=$(/usr/bin/log show --start "$STARTED_AT" --style compact \
  --predicate 'process != "log" AND (eventMessage CONTAINS[c] "not responding" OR eventMessage CONTAINS[c] "connections interrupted")' \
  2>/dev/null | /usr/bin/grep -v '^Filtering' \
  | /usr/bin/grep -c -iE "not responding|connections interrupted" || true)

echo
echo "  seconds until the mount was taken away: ${waited}"
echo "  mounts still there: ${left}"
echo "  times macOS mentioned an interrupted or unresponsive server: ${said:-0}"
if [ "${left:-1}" -eq 0 ] && [ "${said:-0}" -eq 0 ]; then
  echo "RESULT: the mount went on its own in ${waited}s and nobody was told"
  exit 0
fi
if [ "${left:-1}" -ne 0 ]; then
  echo "RESULT: a mount with nothing behind it was still there after ${BOUND}s;" >&2
  echo "        macOS will put up Server connections interrupted for it" >&2
else
  echo "RESULT: the mount went, but macOS had already said something" >&2
fi
exit 1
