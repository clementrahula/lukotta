#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Watch for anything a copy would put in front of somebody.
#
#   ./scripts/watch-for-complaints.sh [seconds]
#
# Item 3 of the open goal is the one that cannot be proved by a copy
# succeeding: no stall anybody sees, no error dialog, no Finder complaint, no
# "some items had to be skipped". A copy that finishes having shown a dialog on
# the way has failed that, and nothing in a byte count says so.
#
# Three things are watched, because they fail differently:
#
#   the copy engine   DesktopServicesHelper and Finder translate an errno into
#                     the 100060 that ends an operation, and log it before the
#                     dialog appears
#   the mount         macOS marks an NFS mount not responding after
#                     nfs.client.initialdowndelay -- five seconds on this Mac,
#                     read from the kernel, not the twelve nfs.conf(5) claims --
#                     and that is what the "server is not responding" notice
#                     comes from
#   the volume        diskarbitrationd removing the disk is the volume vanishing
#                     from under whoever is using it
#
# The predicate matches subsystems rather than the word "nfs", which also
# catches nfcd and NFStorageServer and buries the thing being looked for.
#
# A COUNT OF ZERO IS NOT A RESULT UNTIL THE CHANNEL IS KNOWN TO BE OPEN
#
# This reports "not responding: 0" and there are two ways to get that number:
# nothing complained, or nothing was listening. After a thirteen-gigabyte copy
# reported zero, the logs were checked and the kernel had never delivered a
# single line through this predicate -- not one, across every run kept. That is
# either a very quiet mount or a dead clause, and the two are indistinguishable
# from the output.
#
# Checking it with `log show` said the kernel was silent. That was the wrong
# instrument: `log show` returns nothing here at all, not even unfiltered, so
# it had no opinion to give and was read as one anyway. `log stream` is the
# channel that works, and asked directly it delivered 2546 kernel lines in 25
# seconds. The clause is alive and the zero is a real zero.
#
# Rather than leave that to be rediscovered, --probe asks the question before a
# run: it opens the same kernel channel for a few seconds and refuses to
# pretend a silent one is a clean one.
set -uo pipefail

if [ "${1:-}" = "--probe" ]; then
  echo "checking the kernel channel is open before trusting a zero…"
  n=$(timeout 12 log stream --style compact --predicate 'process == "kernel"' \
        2>/dev/null | grep -cv '^Filtering\|^Timestamp')
  echo "  kernel lines in 12s: $n"
  if [ "${n:-0}" -lt 1 ]; then
    echo "  the kernel delivers nothing; a count of zero from this watcher" >&2
    echo "  would mean nothing was listening, not that nothing complained" >&2
    exit 1
  fi
  echo "  open. a zero from this watcher is a real zero."
  exit 0
fi

DURATION="${1:-3600}"
LOG="${TMPDIR:-/tmp}/lukotta-complaints.log"

: > "$LOG"
log stream --style compact \
  --predicate 'subsystem == "com.apple.DesktopServices" OR process == "diskarbitrationd" OR (process == "kernel" AND eventMessage CONTAINS[c] "nfs server")' \
  >> "$LOG" 2>&1 &
streamer=$!
trap 'kill "$streamer" 2>/dev/null' EXIT

# Timed, not asked. The unresponsive flag was polled every two seconds through
# a copy and never once seen raised, while a plain stat on the same mount took
# 7.7 seconds -- past the five macOS waits before it says the server has stopped
# answering. nfsstat -m answers from client state that did not show it. So the
# request is timed instead, which is the thing the flag is a verdict about.
MOUNT="${2:-}"
if [ -z "$MOUNT" ]; then
  # The engine's shares are named "<device>.local:/mnt/<label>", or by the
  # guest's address when mounted by hand. Matched on the ":/mnt/" both have --
  # not on the address, which the app's own mount does not use, and not on
  # "anylinuxfs", which appears nowhere in the mount table.
  MOUNT=$(mount | awk '/:\/mnt\// {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}')
fi
[ -n "$MOUNT" ] || { echo "no engine mount to watch" >&2; exit 2; }
echo "watching $MOUNT"

SAMPLES="${TMPDIR:-/tmp}/lukotta-latency.log"
: > "$SAMPLES"
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  t0=$(python3 -c 'import time;print(time.time())')
  timeout 30 stat "$MOUNT" >/dev/null 2>&1
  t1=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(f'{($t1-$t0):.3f}')" >> "$SAMPLES"
  sleep 1
done
seen=$(awk '$1 > 5' "$SAMPLES" | wc -l | tr -d ' ')

kill "$streamer" 2>/dev/null
printf '\n=== how long a trivial request took ===\n'
sort -n "$SAMPLES" | awk '{v[NR]=$1} END{
  printf "  n=%d  p50 %.3fs  p90 %.3fs  p99 %.3fs  worst %.3fs\n",
    NR, v[int(NR*0.5)+1], v[int(NR*0.9)+1], v[int(NR*0.99)+1], v[NR]}'
printf '  over 2s: %s   over 5s (the threshold): %s\n' \
  "$(awk '$1 > 2' "$SAMPLES" | wc -l | tr -d ' ')" "$seen"
printf '\n%s samples past the point macOS says the server is not responding\n' "$seen"
printf 'copy-engine errors: %s\n' \
  "$(grep -cE 'CopyEngine.*(Error [0-9]+|TranslateRawPOSIXError|100060)' "$LOG" 2>/dev/null | head -1)"
printf 'items skipped:      %s\n' \
  "$(grep -ciE 'skipp?ed|could not be (copied|read|written)' "$LOG" 2>/dev/null | head -1)"
printf 'volumes removed:    %s\n' \
  "$(grep -c 'removed disk' "$LOG" 2>/dev/null | head -1)"
printf 'full log in %s\n' "$LOG"
