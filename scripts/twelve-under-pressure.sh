#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Item 8, end to end, in one action: a dozen volumes open through the app on a
# Mac squeezed to what an 8 GB one has, with the count of volumes still served
# sampled the whole way through.
#
# WHY IT IS ONE ACTION
#
# It was three -- open the twelve, hold them, run the ballast beside them -- and
# on 2026-09-03 that arrangement produced a result nobody could read. The
# footprint table fell from 1246 MB to 1 MB and stayed there, which was taken
# for the app releasing memory under pressure; afterwards there were no mounts,
# no machines, and the disk images had been detached. All twelve had died and
# the table had no column that could say so.
#
# So the count is sampled beside the megabytes now, and the whole thing runs as
# one script whose output is one story rather than three logs to line up by
# their clocks.
#
#   ./scripts/twelve-under-pressure.sh
#   COUNT=6 ./scripts/twelve-under-pressure.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
COUNT="${COUNT:-12}"
SP="${SCRATCH:-/tmp}"
LOG="$SP/twelve-under-pressure.log"

# Run from a copy, so editing these scripts while a forty-minute run is in
# flight cannot change what the run is doing. ship.sh does the same, for the
# same reason and after the same kind of surprise.
COPY="$(mktemp -d)"
trap 'rm -rf "$COPY"' EXIT
cp scripts/crowd-through-the-app.sh scripts/eight-gig-pressure.sh \
   scripts/footprint.sh "$COPY/"

echo "opening $COUNT and holding them" | tee "$LOG"
rm -f /tmp/.crowd-release
HOLD=1 COUNT="$COUNT" bash "$COPY/crowd-through-the-app.sh" >> "$LOG" 2>&1 &
crowd=$!

# Wait for the hold, and give up if the opens never finish.
held=0
for _ in $(seq 1 600); do
  /usr/bin/grep -q 'holding .* volumes open' "$LOG" && { held=1; break; }
  kill -0 "$crowd" 2>/dev/null || break
  sleep 1
done
if [ "$held" != "1" ]; then
  echo "the twelve never came up; nothing to measure" >&2
  tail -5 "$LOG" >&2
  touch /tmp/.crowd-release; wait "$crowd" 2>/dev/null
  exit 1
fi

served_now() { mount | /usr/bin/grep -c ':/mnt/'; }
echo
echo "held: $(served_now) volumes served before any pressure"

# Sampled every five seconds rather than thirty, because what is being looked
# for is the moment they stop being served, and thirty seconds is long enough
# to lose it.
bash "$COPY/footprint.sh" 900 5 > "$SP/twelve-pressure-footprint.log" 2>&1 &
sampler=$!

bash "$COPY/eight-gig-pressure.sh" 2>&1 | tee -a "$LOG"
kill "$sampler" 2>/dev/null

after="$(served_now)"
echo
echo "=== served, sampled every five seconds ==="
cat "$SP/twelve-pressure-footprint.log"

echo
echo "volumes served after the pressure: $after of $COUNT"
lowest="$(awk 'NR > 1 && $2 ~ /^[0-9]+$/ {print $2}' \
  "$SP/twelve-pressure-footprint.log" | sort -n | head -1)"
echo "fewest served at any sample: ${lowest:-unknown} of $COUNT"

touch /tmp/.crowd-release
wait "$crowd" 2>/dev/null

echo
if [ "${lowest:-0}" -eq "$COUNT" ] 2>/dev/null; then
  echo "RESULT: all $COUNT stayed served throughout the squeeze"
else
  echo "RESULT: down to ${lowest:-unknown} of $COUNT while squeezed" >&2
  exit 1
fi
