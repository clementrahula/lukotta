#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What a person sees when Finder copies onto a volume and deletes from it,
# measured identically on any volume so a Lukotta volume can be held to what a
# native Mac drive does. Finder's own engine, driven by osascript.
#
#   ./scripts/finder-parity.sh <directory-on-the-volume>
#   MB=1024 FILES=20000 ./scripts/finder-parity.sh /Volumes/TEST
set -uo pipefail

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"

TARGET="${1:-}"
[ -n "$TARGET" ] && [ -d "$TARGET" ] || {
  echo "usage: $0 <directory-on-the-volume>" >&2; exit 2; }
MB="${MB:-1024}"
FILES="${FILES:-20000}"
BIG_FILES=4
RUN="parity-$$-$(date +%H%M%S)"

WORK="$(mktemp -d)"
trap 'rm -f "$WORK/observing"; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/big" "$WORK/tree"
each=$(( MB / BIG_FILES ))
for i in $(seq 1 "$BIG_FILES"); do
  dd if=/dev/urandom of="$WORK/big/large-$i.bin" bs=1048576 count="$each" status=none
done
/usr/bin/python3 - "$WORK/tree" "$FILES" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
for i in range(n):
    d = os.path.join(root, f"dir-{i // 1000:04d}")
    if i % 1000 == 0:
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"file-{i:07d}.bin"), "wb") as fh:
        fh.write(os.urandom(4096))
PY

finder_windows() {
  osascript -e 'tell application "System Events" to tell process "Finder" to get name of every window' \
    2>/dev/null | tr ',' '\n' | sed 's/^ *//' | sort
}

# Once per interval while a copy runs: Finder's windows, and in the destination
# the "._" companions, the zero-length files and the rest.
observe() {  # destination, samples file, interval
  while [ -e "$WORK/observing" ]; do
    local names counts
    names="$(finder_windows | paste -sd'|' -)"
    counts="$(find "$1" -mindepth 1 \
      \( -name '._*' -printf 'dot\n' \) -o \
      \( -type f -size 0 -printf 'empty\n' \) -o \
      \( -type f -printf 'full\n' \) 2>/dev/null | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
    printf '%s\t%s\t%s\n' "$(date +%s.%N)" "$names" "$counts" >> "$2"
    sleep "$3"
  done
}

# "with timeout" is not optional: an Apple event gives up after two minutes and
# osascript reports -1712 while Finder carries on.
finder_copy() {  # source folder, destination folder
  osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    with timeout of 86400 seconds
      duplicate (every item of (POSIX file (item 1 of argv) as alias)) to (POSIX file (item 2 of argv) as alias) with replacing
    end timeout
  end tell
end run
APPLESCRIPT
}

# Finder's delete is the one Command-Delete runs: to the Trash, where there is one.
finder_delete() {  # item
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    with timeout of 86400 seconds
      delete (POSIX file (item 1 of argv) as alias)
    end timeout
  end tell
end run
APPLESCRIPT
}

verify() {  # source, destination
  local bad=0 missing=0 good=0 rel d
  while IFS= read -r f; do
    rel="${f#"$1"/}"; d="$2/$rel"
    if [ ! -f "$d" ]; then missing=$((missing + 1)); continue; fi
    if cmp -s "$f" "$d"; then good=$((good + 1)); else bad=$((bad + 1)); fi
  done < <(find "$1" -type f)
  echo "$good identical, $bad differing, $missing missing"
  [ "$bad" -eq 0 ] && [ "$missing" -eq 0 ]
}

failures=0
before_windows="$(finder_windows)"

for shape in big tree; do
  dst="$TARGET/$RUN-$shape"
  mkdir -p "$dst"
  samples="$WORK/$shape.samples"
  : > "$samples"
  touch "$WORK/observing"
  interval=1; [ "$shape" = tree ] && interval=3
  observe "$dst" "$samples" "$interval" &
  watcher=$!

  start=$(date +%s.%N)
  err="$(finder_copy "$WORK/$shape" "$dst" 2>&1 >/dev/null)"; rc=$?
  end=$(date +%s.%N)
  rm -f "$WORK/observing"; wait "$watcher" 2>/dev/null

  secs=$(awk -v a="$start" -v b="$end" 'BEGIN {printf "%.1f", b - a}')
  bytes=$(find "$WORK/$shape" -type f -printf '%s\n' | awk '{s += $1} END {print s + 0}')
  rate=$(awk -v b="$bytes" -v s="$secs" 'BEGIN {printf "%.1f", b / s / 1e6}')
  result="$(verify "$WORK/$shape" "$dst")"; ok=$?

  # A progress window is any Finder window seen during the copy that was not
  # there before it began.
  progress="$(cut -f2 "$samples" | tr '|' '\n' | sed '/^$/d' | sort -u |
    comm -13 <(printf '%s\n' "$before_windows") - | paste -sd',' -)"
  most_empty=$(grep -o 'empty=[0-9]*' "$samples" | cut -d= -f2 | sort -n | tail -1)
  most_dot=$(grep -o 'dot=[0-9]*' "$samples" | cut -d= -f2 | sort -n | tail -1)
  left_dot=$(find "$dst" -name '._*' 2>/dev/null | wc -l | tr -d ' ')

  printf '%-4s copy    %6ss  %6s MB/s  osascript %s%s  %s\n' "$shape" "$secs" "$rate" "$rc" \
    "${err:+ ($err)}" "$result"
  printf '%-4s finder  progress window: %s; zero-length seen at once: %s; ._ seen: %s, left: %s\n' \
    "$shape" "${progress:-none}" "${most_empty:-0}" "${most_dot:-0}" "$left_dot"
  { [ "$rc" -eq 0 ] && [ "$ok" -eq 0 ]; } || failures=$((failures + 1))
done

victim="$TARGET/$RUN-tree"
start=$(date +%s.%N)
err="$(finder_delete "$victim" 2>&1 >/dev/null)"; rc=$?
end=$(date +%s.%N)
secs=$(awk -v a="$start" -v b="$end" 'BEGIN {printf "%.2f", b - a}')
if [ -e "$victim" ]; then where="still there"; else where="gone from its folder"; fi
printf 'tree delete   %6ss  osascript %s%s  %s\n' "$secs" "$rc" "${err:+ ($err)}" "$where"
{ [ "$rc" -eq 0 ] && [ ! -e "$victim" ]; } || failures=$((failures + 1))

# The Trash is never emptied from here: that empties every Trash on the Mac.
# What this run put in the volume's own Trash comes back out by name.
mount_point="$(df "$TARGET" | awk 'NR==2 {print $NF}')"
for trashed in "$mount_point/.Trashes/$(id -u)/$RUN-"*; do
  [ -e "$trashed" ] && rm -rf "$trashed"
done
rm -rf "$TARGET/$RUN-big" "$TARGET/$RUN-tree"

printf '%s failures\n' "$failures"
[ "$failures" -eq 0 ]
