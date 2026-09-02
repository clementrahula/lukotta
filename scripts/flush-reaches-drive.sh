#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Whether a guest barrier reaches the drive, timed rather than crashed.
#
#   ./scripts/flush-reaches-drive.sh <mounted-volume> [count]
#
# The durability test kills the machine, which on the one physical drive here
# means doing that to somebody's only backup. This asks a narrower question
# that needs no kill: a cache flush a drive actually performs costs a round
# trip to the drive, and a flush answered by a no-op costs nothing. So the
# latency of a small `dd conv=fsync` says whether the barrier is being carried
# out.
#
# **It did not work, and the numbers are here so nobody runs it again
# expecting them to.** Measured on the one physical drive, 1 MiB a write,
# twenty writes, the same drive either side of the change:
#
#     engine without patches/imago-flush-device-nodes.patch   median 121.5 ms
#     engine with it                                          median 117.0 ms
#
# The patched one is marginally faster, which is noise. Smaller writes did not
# separate them either: 4 KiB came out at 41.2 ms and 64 KiB at 35.9 ms, both
# far larger than any cache flush and both dominated by the NFS round trip and
# the guest's own path. A device flush of a few milliseconds cannot be seen
# underneath that.
#
# So this measures nothing about the flush. Whether the barrier reaches the
# drive is answered by kill-durability.sh on a real drive, and by nothing
# cheaper found so far.
set -u

MOUNT="${1:?usage: flush-reaches-drive.sh <mounted-volume> [count]}"
COUNT="${2:-20}"
DIR="$MOUNT/lukotta-flush-timing"

[ -d "$MOUNT" ] || { echo "no such volume: $MOUNT"; exit 1; }
mkdir -p "$DIR" || { echo "cannot write to $MOUNT"; exit 1; }
trap 'rm -rf "$DIR"' EXIT

# One megabyte a time: large enough that the write itself is not noise, small
# enough that the flush dominates.
times=()
for i in $(seq 1 "$COUNT"); do
  start=$(python3 -c 'import time; print(time.monotonic())')
  dd if=/dev/urandom of="$DIR/f$i.bin" bs=1048576 count=1 conv=fsync status=none
  end=$(python3 -c 'import time; print(time.monotonic())')
  times+=("$(python3 -c "print(f'{($end - $start) * 1000:.1f}')")")
done

printf '%s\n' "${times[@]}" | python3 -c '
import sys
v = sorted(float(x) for x in sys.stdin)
n = len(v)
print(f"  n={n}  min {v[0]:.1f} ms  median {v[n//2]:.1f} ms  max {v[-1]:.1f} ms")
print(f"  total {sum(v):.0f} ms for {n} MiB")
'
