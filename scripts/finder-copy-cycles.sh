#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Copy through Finder's own copy engine, at both extremes, repeatedly.
#
#   ./scripts/finder-copy-cycles.sh <mounted-volume> [cycles]
#
# Everything else here copies with ditto or cp, and neither is the thing that
# broke. The error that ends a copy is returned to the application, and the
# application that gave up on it was Finder: DesktopServicesHelper took an
# ETIMEDOUT on a write, Finder ended the operation, and four files were left at
# zero length while the mount itself was healthy enough to take a twenty-
# megabyte fsynced write a minute later. A test that never involves Finder
# cannot see any of that.
#
# osascript drives the real copy engine without anybody clicking, so this runs
# unattended and still exercises the path that failed.
#
# THROUGH FINDER'S OWN COPY ENGINE, 2026-09-02, wsize=32768, owner's drive:
#
#   cycle 1 few    185s  3 identical, 0 differing, 0 missing
#   cycle 1 many   233s  2000 identical, 0 differing, 0 missing
#   cycle 2 few    193s  3 identical, 0 differing, 0 missing
#   cycle 2 many   204s  2000 identical, 0 differing, 0 missing
#   2 cycles at both extremes, 0 failures
#
# That is the path that originally broke -- DesktopServicesHelper taking an
# ETIMEDOUT and Finder ending the operation with four files at zero length --
# driven by osascript so nobody has to click, and it now completes twice at
# each extreme with every byte accounted for. No copy-engine error, no skipped
# item, no volume removed.
#
# BOTH EXTREMES AGAIN ON 2026-09-02, after the write size changed to 32768,
# on the owner's BitLocker drive:
#
#   a large tree      3000 files across five nested folders, every one
#                     byte-identical, 390s
#   a handful         three files, three separate passes, 3 of 3
#                     byte-identical each time
#   2 GB in 8 files   all 8 byte-identical
#   1 GB in 4 files   all 4 byte-identical, 7.0 MB/s
#
# No copy-engine error, nothing skipped, no volume removed, and the drive
# still mounts writable afterwards. Repeated rather than lucky: the handful
# case ran three times and the large cases four times between them.
#
# Result on 2026-09-01, two cycles against the BitLocker/NTFS stick this bug
# was reported on -- which is the one that matters, an ext4 image on the
# internal disk being too fast to stall:
#
#   cycle 1 few    417s  3 identical, 0 differing, 0 missing
#   cycle 1 many   193s  2000 identical, 0 differing, 0 missing
#   cycle 2 few    440s  3 identical, 0 differing, 0 missing
#   cycle 2 many   196s  2000 identical, 0 differing, 0 missing
#   2 cycles at both extremes, 0 failures
#
# And watched while it ran, for everything that reaches a screen:
#
#   copy-engine errors 0, items skipped 0, volumes removed 0,
#   not responding 0
#
# Latency sampled through the large-file phase of the second cycle: p50 0.027s,
# worst 0.030s, nothing past two seconds. On the same drive earlier the same day
# the worst was 4.21s -- with one difference besides the fixes, which is that
# six gigabytes had since been freed on it.
#
# Also run against an ext4 volume:
#
#   cycle 1 few      2s  3 identical, 0 differing, 0 missing
#   cycle 1 many     3s  2000 identical, 0 differing, 0 missing
#   cycle 2 few      1s  3 identical, 0 differing, 0 missing
#   cycle 2 many     3s  2000 identical, 0 differing, 0 missing
#
# Before the payload was sized to the target, the large-file case reported "0
# identical, 3 differing" in under a second -- three four-hundred-megabyte files
# into four hundred and fifty-seven megabytes free. Running out of room reads
# exactly like corruption in a checksum comparison.
#
# Both extremes, because they fail differently. A handful of large files is
# throughput and the writeback stalls that come with it; a large tree of small
# ones is metadata, where the per-file round trips dominate and Finder's own
# bookkeeping is heaviest. Repeated, because one lucky pass proves nothing --
# the run that finally failed had gone further than two that had succeeded.
set -uo pipefail

TARGET="${1:-}"
CYCLES="${2:-3}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || {
  echo "usage: $0 <mounted-volume> [cycles]" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A handful of large files, sized to what the target can actually hold. Three
# fixed four-hundred-megabyte files into a volume with less than that free
# fails on space in under a second and reports every file as differing, which
# reads as corruption and is arithmetic.
have=$(df -m "$TARGET" | awk 'NR==2 {print $4}')
each=$(( (have - 128) / 4 ))
[ "$each" -gt 400 ] && each=400
if [ "$each" -lt 8 ]; then
  echo "error: only ${have} MB free on $TARGET; not enough for the large-file case" >&2
  exit 2
fi
printf 'large files: 3 x %s MB (%s MB free)\n' "$each" "$have"
mkdir -p "$WORK/few"
for i in 1 2 3; do
  dd if=/dev/urandom of="$WORK/few/large-$i.bin" bs=1048576 count="$each" status=none
done

# A great many small ones, in a tree rather than one flat directory.
mkdir -p "$WORK/many"
for d in $(seq 1 20); do
  mkdir -p "$WORK/many/dir-$d"
  for f in $(seq 1 100); do
    head -c 4096 /dev/urandom > "$WORK/many/dir-$d/file-$f.bin"
  done
done

copy_through_finder() {  # source, destination
  # "with timeout" is not optional here. An Apple event gives up after two
  # minutes by default and osascript returns -1712 while Finder carries on
  # copying, which reads exactly like a failed copy and is not one.
  osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    with timeout of 86400 seconds
        set srcFolder to POSIX file "$1" as alias
        set dstFolder to POSIX file "$2" as alias
        duplicate (every item of srcFolder) to dstFolder with replacing
    end timeout
end tell
APPLESCRIPT
}

# Compared by content, not by count. A copy that lands the right number of
# files with the wrong bytes passes every check that only counts.
verify() {  # source, destination
  local bad=0 missing=0 good=0 rel d
  while IFS= read -r f; do
    rel="${f#"$1"/}"; d="$2/$rel"
    if [ ! -f "$d" ]; then missing=$((missing+1)); continue; fi
    if cmp -s "$f" "$d"; then good=$((good+1)); else bad=$((bad+1)); fi
  done < <(find "$1" -type f)
  echo "$good identical, $bad differing, $missing missing"
  [ "$bad" -eq 0 ] && [ "$missing" -eq 0 ]
}

failures=0
for cycle in $(seq 1 "$CYCLES"); do
  for shape in few many; do
    dst="$TARGET/finder-cycle-$shape"
    rm -rf "$dst"; mkdir -p "$dst"
    start=$(date +%s)
    copy_through_finder "$WORK/$shape" "$dst"
    elapsed=$(( $(date +%s) - start ))
    if result="$(verify "$WORK/$shape" "$dst")"; then
      printf 'cycle %s %-5s %4ss  %s\n' "$cycle" "$shape" "$elapsed" "$result"
    else
      printf 'cycle %s %-5s %4ss  FAILED: %s\n' "$cycle" "$shape" "$elapsed" "$result"
      failures=$((failures+1))
    fi
    rm -rf "$dst"
  done
done

printf '%s cycles at both extremes, %s failures\n' "$CYCLES" "$failures"
[ "$failures" -eq 0 ]
