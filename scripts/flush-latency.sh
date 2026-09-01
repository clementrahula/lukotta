#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# How long a trivial request takes while a large file is being flushed.
#
#   ./scripts/flush-latency.sh <mounted-volume> [megabytes] [files]
#
# The fault worth chasing is not that a copy is slow. It is that a copy which
# finishes perfectly can still make macOS tell somebody the server has stopped
# answering, and it does that when a request goes unanswered for five seconds.
#
# Measured over a thirteen-gigabyte copy: p50 28ms, p90 31ms, p99 4.66s, worst
# 8.95s, nine requests past five seconds. Reading the same thirteen gigabytes
# back off the same drive: worst 43ms, nothing over two seconds at all. So the
# tail belongs to writing, and to what happens to other requests while
# committed data is pushed out -- the slow moments cluster in the thirty to
# fifty seconds after each file closes.
#
# Which means the whole copy is not needed to see it. One large file, written
# and closed, reproduces the same window in about ninety seconds instead of
# fifty-five minutes -- and an experiment that costs ninety seconds gets run
# against every setting worth trying, while one that costs an hour gets run
# against the first guess and believed.
#
# The reading is the distribution, never a pass or a fail: a worst case of four
# seconds is one bad moment from the dialog and looks like success.
set -uo pipefail
TARGET="${1:-}"
MB="${2:-500}"
FILES="${3:-1}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "usage: $0 <mounted-volume> [mb] [files]" >&2; exit 2; }

WORK="$(mktemp -d)"
DST="$TARGET/flush-latency-test"
SAMPLES="$WORK/samples"
trap 'rm -rf "$WORK" "$DST"' EXIT
mkdir -p "$DST"
: > "$SAMPLES"

# Timed from here, so the flush window after the last close is included -- that
# is where the slow moments are, not during the write itself.
( while [ ! -f "$WORK/stop" ]; do
    t0=$(python3 -c 'import time;print(time.time())')
    timeout 30 stat "$TARGET" >/dev/null 2>&1
    t1=$(python3 -c 'import time;print(time.time())')
    python3 -c "print(f'{($t1-$t0):.3f}')" >> "$SAMPLES"
    sleep 0.5
  done ) &
sampler=$!

start=$(date +%s)
for i in $(seq 1 "$FILES"); do
  dd if=/dev/urandom of="$DST/big-$i.bin" bs=1048576 count="$MB" status=none
  sync
done
written=$(( $(date +%s) - start ))

# Keep sampling through the flush that follows the last close.
sleep 45
touch "$WORK/stop"; wait "$sampler" 2>/dev/null

printf '%s MB in %s file(s), written in %ss\n' "$((MB * FILES))" "$FILES" "$written"
sort -n "$SAMPLES" | awk '{v[NR]=$1} END{
  printf "  n=%d  p50 %.3fs  p90 %.3fs  p99 %.3fs  worst %.3fs\n",
    NR, v[int(NR*0.5)+1], v[int(NR*0.9)+1], v[int(NR*0.99)+1], v[NR]}'
printf '  over 2s: %s   over 5s (the threshold): %s\n' \
  "$(awk '$1 > 2' "$SAMPLES" | wc -l | tr -d ' ')" \
  "$(awk '$1 > 5' "$SAMPLES" | wc -l | tr -d ' ')"
