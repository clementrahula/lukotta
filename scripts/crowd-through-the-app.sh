#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A dozen volumes open at once, opened the way a person opens them.
#
# WHY THIS EXISTS SEPARATELY FROM THE MEASUREMENT ALREADY WRITTEN DOWN
#
# Twelve volumes were measured on 2026-09-03 and the numbers are in
# MEASUREMENTS.md: 1.87 GB in total, byte-identical on all twelve, a shell
# still answering in 28 ms. Every one of those was opened by calling the engine
# directly, and the engine takes a loopback address as it finds one.
#
# The app does not. It asks its daemon for twelve addresses first and will not
# open a drive it has no address for -- and until 1.22.7-beta.2 the daemon
# counted ::1 and fe80::1 among them, answered twelve when ten existed, and
# added nothing. So the app could never have opened more than ten, and the
# measurement that said a dozen worked had not been anywhere near the code that
# would have shown it.
#
# This opens them through the app, one `--drive open=` at a time, exactly as
# the window does. If the ceiling is still there it appears here and nowhere
# else.
#
#   ./scripts/crowd-through-the-app.sh
#   COUNT=12 ./scripts/crowd-through-the-app.sh
#
# LUKOTTA_ENGINE names the bundle to test, and it must be one whose daemon is
# installed -- see the note in dirty-ntfs-repair.sh about a channel with none.
set -uo pipefail

OUT="${1:-$HOME/.lukotta-testvols}"
COUNT="${COUNT:-12}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"

[ -f "/Library/LaunchDaemons/$APP_ID.helper.plist" ] || {
  echo "error: no daemon for $APP_ID; this channel cannot mount on this Mac" >&2
  exit 2
}
[ -d "$OUT/crowd" ] || {
  echo "error: no volumes in $OUT/crowd; run make-test-volumes.sh --crowd" >&2
  exit 2
}

WORK="$(mktemp -d)"
DEVS=()
fail=0

clean_up() {
  for point in $(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | sort -u); do
    umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1
  done
  for dev in "${DEVS[@]:-}"; do
    [ -n "$dev" ] && hdiutil detach "$dev" -quiet >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap clean_up EXIT

echo "opening $COUNT volumes through $APP_ID, one at a time"
echo "  lo0 carries $(ifconfig lo0 | /usr/bin/grep -c 'inet ') addresses that can serve"

opened=0
for i in $(seq 1 "$COUNT"); do
  img="$OUT/crowd/drive$i.img"
  [ -f "$img" ] || { echo "  no $img" >&2; fail=1; continue; }
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$img" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${dev:-}" ] || { echo "  drive$i would not attach" >&2; fail=1; continue; }
  DEVS+=("$dev")
  # Each open returns once the volume is served, so these are sequential and
  # the count below is the count that survived, not the count attempted.
  began="$(date +%s)"
  if timeout 300 "$APP" --drive open="$dev" > "$WORK/open$i.log" 2>&1; then
    opened=$((opened + 1))
    took=$(( $(date +%s) - began ))
    echo "$took" >> "$WORK/opens"
    printf '  %2d of %s open, %s s\n' "$opened" "$COUNT" "$took"
  else
    echo "  drive$i did not open: $(tail -1 "$WORK/open$i.log")" >&2
    fail=1
  fi
done

# How long each one took, which is what somebody waiting actually feels. The
# last is the one that matters: if opening the twelfth costs more than opening
# the first, the app is paying for the ones already open.
if [ -s "$WORK/opens" ]; then
  printf 'seconds to open: first %s, last %s, slowest %s\n' \
    "$(head -1 "$WORK/opens")" "$(tail -1 "$WORK/opens")" \
    "$(sort -n "$WORK/opens" | tail -1)"
fi

served="$(mount | /usr/bin/grep -c 'CROWD')"
echo "mounts being served: $served"
echo "  lo0 now carries $(ifconfig lo0 | /usr/bin/grep -c 'inet ') addresses that can serve"

# Written to all of them at once, then read back. Sums taken from the source,
# not from the volume, so a file that never arrived is a difference and not a
# matching pair of absences.
mount | /usr/bin/grep 'CROWD' | awk '{print $3}' > "$WORK/points"
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 60); do head -c 100000 /dev/urandom > "$SRC/f$i.bin"; done
(cd "$SRC" && find . -type f -exec shasum -a 256 {} \; | sort) > "$WORK/before.sums"

started="$(date +%s)"
while read -r point; do
  ditto "$SRC" "$point/crowd-write" >/dev/null 2>&1 &
done < "$WORK/points"
wait
echo "wrote to $(wc -l < "$WORK/points" | tr -d ' ') volumes in $(( $(date +%s) - started )) s"

identical=0; differing=0
while read -r point; do
  (cd "$point/crowd-write" && find . -type f -exec shasum -a 256 {} \; | sort) \
    > "$WORK/after.sums" 2>/dev/null
  if diff -q "$WORK/before.sums" "$WORK/after.sums" >/dev/null 2>&1; then
    identical=$((identical + 1))
  else
    differing=$((differing + 1))
    echo "  $point differs" >&2
  fi
done < "$WORK/points"
echo "byte-identical on $identical, wrong on $differing"
[ "$differing" -eq 0 ] || fail=1

# What it costs, and whether the Mac is still usable while it does.
rss="$(ps -Ao rss=,command= | /usr/bin/grep -E 'anylinuxfs|krun|vmproxy' \
  | /usr/bin/grep -v grep | awk '{sum += $1} END {print int(sum / 1024)}')"
procs="$(pgrep -c -f 'anylinuxfs|krun|vmproxy' 2>/dev/null || echo 0)"
echo "engines: $procs processes, ${rss:-0} MB resident in total"
shell_ms="$( { time -p /bin/echo hello >/dev/null ; } 2>&1 \
  | awk '/^real/ {printf "%d", $2 * 1000}')"
echo "shell responsiveness: ${shell_ms} ms for a trivial command"

echo
if [ "$opened" -lt "$COUNT" ]; then
  echo "RESULT: $opened of $COUNT opened through the app" >&2
  fail=1
else
  echo "RESULT: all $COUNT opened through the app, $identical byte-identical"
fi
exit "$fail"
