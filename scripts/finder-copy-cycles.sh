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
