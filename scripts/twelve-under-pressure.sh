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
cd "$HERE" || exit 1
COUNT="${COUNT:-12}"
SP="${SCRATCH:-/tmp}"
LOG="$SP/twelve-under-pressure.log"

# Run from a copy, so editing these scripts while a forty-minute run is in
# flight cannot change what the run is doing. ship.sh does the same, for the
# same reason and after the same kind of surprise.
COPY="$(mktemp -d)"
trap 'rm -rf "$COPY"' EXIT
cp scripts/crowd-through-the-app.sh scripts/eight-gig-pressure.sh \
   scripts/footprint.sh scripts/copy-visibility.sh "$COPY/"

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

# Worked before they are squeezed, because the one run in which all twelve died
# had been through 324 copies first and the run that survived had not. A volume
# that has just been opened holds almost nothing; one that has been copied onto
# for ten minutes holds a page cache, and it is the second that a person has
# when their Mac runs short. Squeezing the empty case only is squeezing the
# easy one.
if [ "${EXERCISE:-1}" = "1" ]; then
  echo
  echo "working them before the squeeze"
  # KEEP=1 leaves every cycle in place, which fills the volumes as it works.
  # The run in which all twelve died had been left that way -- 18 MB of files
  # kept on 64 MB volumes with 33 MB free -- and a nearly full volume is both
  # one of item 9's named vectors and the last known difference between that
  # run and the ones that survived.
  KEEP="${EXERCISE_KEEP:-0}" CYCLES="${EXERCISE_CYCLES:-15}" \
    FILES="${EXERCISE_FILES:-60}" \
    bash "$COPY/copy-visibility.sh" 2>&1 | tail -6 | tee -a "$LOG"
  echo "  free on each volume after the work:"
  mount | /usr/bin/grep ':/mnt/' | awk '{print $3}' | while read -r p; do
    printf '    %-24s %s\n' "$p" "$(df -h "$p" | tail -1 | awk '{print $4 " free of " $2}')"
  done | tee -a "$LOG"
  echo "still served after the work: $(served_now)"
fi

# Sampled every five seconds rather than thirty, because what is being looked
# for is the moment they stop being served, and thirty seconds is long enough
# to lose it.
bash "$COPY/footprint.sh" 900 5 > "$SP/twelve-pressure-footprint.log" 2>&1 &
sampler=$!

bash "$COPY/eight-gig-pressure.sh" 2>&1 | tee -a "$LOG"
kill "$sampler" 2>/dev/null

# The responsiveness half of item 8, judged rather than printed.
#
# "with the machine still responsive for ordinary use" is half of what item 8
# asks, and it was being answered by three latencies scrolling past in a log
# that nothing read. A number nothing decides on is a number nobody checked:
# this row could have gone green with the home listing taking four seconds.
#
# Ordinary use here is what eight-gig-pressure.sh already times under the
# ballast -- listing a home directory, walking a source tree, launching a
# process -- plus the kernel's own verdict beside them. A second is where a
# person stops experiencing a machine as responsive and starts waiting for it,
# so a second is the bound. Critical pressure, or anything killed for sustained
# pressure, fails on its own: that is the way a dozen volumes stop being served
# on a small Mac.
# Each label read on its own, because one clever pipeline that comes back
# empty is indistinguishable here from a machine that was never timed -- and
# an empty answer must fail this, not pass it. That is why the check below
# also refuses a run in which nothing was timed at all.
slowest=0; slowest_what=""
for what in "home listing" "spotlight-free find" "process launch"; do
  ms="$(/usr/bin/grep -F "  $what " "$LOG" | tail -1 | awk '{print $(NF-1)}')"
  case "${ms:-}" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$ms" -gt "$slowest" ]; then slowest="$ms"; slowest_what="$what"; fi
done
level="$(sed -n 's/^  kernel pressure level  *//p' "$LOG" | tail -1)"
killed="$(sed -n 's/^  killed for sustained pressure  *\([0-9][0-9]*\) during this run$/\1/p' "$LOG" | tail -1)"
# Into the log as well as onto the screen. The row's own output is thrown away
# when it passes, so a verdict that only reaches the screen is a verdict nobody
# can read afterwards -- which is how these three latencies came to be printed
# for weeks with nothing keeping them.
{
  echo
  echo "=== the machine, while the twelve were squeezed ==="
  echo "  slowest ordinary action      ${slowest} ms (${slowest_what:-none timed})"
  echo "  kernel pressure level        ${level:-unknown}"
  echo "  killed for sustained pressure ${killed:-unknown}"
} | tee -a "$LOG"
responsive=1
[ "$slowest" -le 1000 ] 2>/dev/null || { echo "  FAIL: ordinary use took ${slowest} ms" >&2; responsive=0; }
[ "${level:-unknown}" != "critical" ] || { echo "  FAIL: the kernel called the pressure critical" >&2; responsive=0; }
[ "${killed:-0}" = "0" ] || { echo "  FAIL: ${killed} killed for sustained pressure" >&2; responsive=0; }
[ -n "$slowest_what" ] || { echo "  FAIL: nothing was timed; the latencies were not printed" >&2; responsive=0; }

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
if [ "${lowest:-0}" -eq "$COUNT" ] 2>/dev/null && [ "$responsive" = "1" ]; then
  echo "RESULT: all $COUNT stayed served throughout the squeeze, and the machine stayed usable"
elif [ "${lowest:-0}" -eq "$COUNT" ] 2>/dev/null; then
  echo "RESULT: all $COUNT stayed served, but the machine did not stay usable" >&2
  exit 1
else
  echo "RESULT: down to ${lowest:-unknown} of $COUNT while squeezed" >&2
  exit 1
fi
