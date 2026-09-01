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
set -uo pipefail
DURATION="${1:-3600}"
LOG="${TMPDIR:-/tmp}/lukotta-complaints.log"

: > "$LOG"
log stream --style compact \
  --predicate 'subsystem == "com.apple.DesktopServices" OR process == "diskarbitrationd" OR (process == "kernel" AND eventMessage CONTAINS[c] "nfs server")' \
  >> "$LOG" 2>&1 &
streamer=$!
trap 'kill "$streamer" 2>/dev/null' EXIT

state=up
seen=0
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  # nfsstat blocks on a wedged mount, so its own hanging is the signal.
  flags=$(timeout 5 nfsstat -m 2>/dev/null \
          | sed -n '/Volumes/,/Status flags/p' | grep -o 'Status flags: 0x[0-9a-f]*' | head -1)
  rc=$?
  if [ "$rc" -eq 124 ] || [ -z "$flags" ] || [ "$flags" != "Status flags: 0x0" ]; then
    now=down
  else
    now=up
  fi
  if [ "$now" != "$state" ]; then
    printf '%s  mount %s -> %s\n' "$(date '+%H:%M:%S')" "$state" "$now"
    [ "$now" = down ] && seen=$((seen + 1))
    state="$now"
  fi
  sleep 2
done

kill "$streamer" 2>/dev/null
printf '\n%s spells of the mount not answering\n' "$seen"
printf 'copy-engine errors: %s\n' \
  "$(grep -cE 'CopyEngine.*(Error [0-9]+|TranslateRawPOSIXError|100060)' "$LOG" 2>/dev/null || echo 0)"
printf 'items skipped:      %s\n' \
  "$(grep -ciE 'skipp?ed|could not be (copied|read|written)' "$LOG" 2>/dev/null || echo 0)"
printf 'volumes removed:    %s\n' \
  "$(grep -c 'removed disk' "$LOG" 2>/dev/null || echo 0)"
printf 'full log in %s\n' "$LOG"
