#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What an open drive costs, sampled rather than glanced at.
#
#   ./scripts/footprint.sh [seconds] [interval]
#
# The app claims a dozen volumes can be open at once. Whether that is true on
# an eight-gigabyte Mac is a memory question, and memory questions get answered
# with a single `ps` at a convenient moment far too often -- that is how 502 MB
# and 344 MB were both called "the" number for the same machine on the same
# day. The figure moves through a copy, so it is sampled through one.
#
# Measured while thirteen gigabytes went into a USB drive through Finder, one
# drive open, 512 MiB guest, 24 samples thirty seconds apart:
#
#   microVM and its two helpers   min 315 MB, median 444 MB, max 455 MB
#   host free                     min  15 MB, median  42 MB, max  93 MB
#   host compressed               min 1222 MB, median 1311 MB, max 1489 MB
#
# At a median of 444 MB each, twelve drives is about 5.3 GB before macOS has
# taken anything, which this Mac does not have. The machine stayed usable on
# one -- 3.6 ms to spawn a process, 60 ms to list a home directory, 2166 MB/s
# to the internal disk -- so the cost is memory rather than responsiveness.
set -uo pipefail
DURATION="${1:-600}"
INTERVAL="${2:-30}"

printf '%-8s %8s %8s %10s\n' time vm_mb free_mb compressed_mb
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  # pgrep for the pids and ps for their sizes, rather than grepping ps output:
  # the grep matches itself often enough to be worth avoiding.
  read -ra pids < <(pgrep -f 'anylinuxfs|vmnet-helper')
  if [ "${#pids[@]}" -gt 0 ]; then
    vm=$(ps -o rss= -p "${pids[@]}" 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}')
  else
    vm=0
  fi
  read -r free comp <<<"$(vm_stat | awk '
    /Pages free/{f=$3} /Pages occupied by compressor/{c=$5}
    END{gsub(/\./,"",f); gsub(/\./,"",c); printf "%d %d", f*4096/1048576, c*4096/1048576}')"
  printf '%-8s %8s %8s %10s\n' "$(date '+%H:%M:%S')" "${vm:-0}" "$free" "$comp"
  sleep "$INTERVAL"
done
