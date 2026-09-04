#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What a durability option costs on a large write, as a number.
#
# WHY
#
# XFS is given `-o sync` in the guest because it has no data-journalling mode,
# and a LUKS container is given a synchronous client because the superblock
# inside it cannot be read to choose anything cheaper. ExtJournal.swift says
# `-o sync` "costs nothing on a large file at all" and quotes 190 MB/s; the
# format sweep's own fill timings put XFS at about 16 MB/s against ext4's 316.
#
# Both cannot be right, and item 10 -- no UX cost anywhere -- rests on which is.
# A copy that runs twenty times slower is a UX cost whatever else is true, so
# this asks the question directly rather than inferring it from a vector that
# was timing something else.
#
# It measures the option, not the app: the same volume, the same file, mounted
# by the engine with the option and without it. That isolates the one variable,
# which is what the question is about.
#
#   ./scripts/durability-cost.sh
#   IMAGE=plain-ext4.img OPTION=data=journal ./scripts/durability-cost.sh
#   MB=2000 ./scripts/durability-cost.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-plain-xfs.img}"
OPTION="${OPTION:-sync}"
MB="${MB:-1000}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
[ -f "$OUT/$IMAGE" ] || { echo "error: no $OUT/$IMAGE" >&2; exit 2; }

WORK="$(mktemp -d)"
release() {
  for p in $(mount | /usr/bin/grep '\.local:' | awk '{print $3}' \
             | awk '{print length, $0}' | sort -rn | cut -d" " -f2-); do
    umount "$p" >/dev/null 2>&1 || umount -f "$p" >/dev/null 2>&1
  done
  /usr/bin/pkill -f "anylinuxfs mount" >/dev/null 2>&1
  sleep 2
}
trap 'release; rm -rf "$WORK"' EXIT
release

# A copy of the fixture, so a run cannot spoil the next one, and a fresh
# filesystem each time: a volume being filled to its last block is a different
# question from a volume with room, and mixing them is how the two numbers in
# the record came to disagree.
cp "$OUT/$IMAGE" "$WORK/t.img" || exit 2

time_one() {
  local opts="$1" label="$2"  # $3 names the file the seconds are kept in
  release
  cp "$OUT/$IMAGE" "$WORK/t.img"
  local args=()
  [ -n "$opts" ] && args=(-o "$opts")
  # --ignore-permissions, as the app passes. Without it the volume is served
  # with its Linux ownership intact, which for these fixtures is root, and every
  # write here failed with "Permission denied" -- reported as 0 MB arriving,
  # which at least said so rather than being timed as a fast write.
  nohup "$ENGINE" mount -w false --ignore-permissions "${args[@]}" "$WORK/t.img" \
    > "$WORK/engine.log" 2>&1 &
  local point=""
  for _ in $(seq 1 60); do
    point="$(mount | /usr/bin/grep '\.local:' | awk '{print $3}' | head -1)"
    [ -n "$point" ] && break
    sleep 2
  done
  [ -n "$point" ] || { printf '  %-22s did not mount\n' "$label"; return 1; }

  # Checked, not assumed. dd's complaint used to go to /dev/null, so a write
  # that never happened came back as "1 s, 1000 MB/s" -- twice, identically,
  # which is what said it was not writing at all rather than writing fast.
  local began ended secs arrived
  began=$(date +%s)
  dd if=/dev/zero of="$point/durability-probe.bin" bs=1048576 count="$MB" \
    conv=fsync status=none 2>"$WORK/dd.err"
  ended=$(date +%s)
  arrived=$(( $(wc -c < "$point/durability-probe.bin" 2>/dev/null || echo 0) / 1048576 ))
  if [ "$arrived" -lt "$MB" ]; then
    printf '  %-22s only %s MB of %s arrived: %s\n' "$label" "$arrived" "$MB" \
      "$(head -1 "$WORK/dd.err" 2>/dev/null)"
    release; return 1
  fi
  secs=$(( ended - began )); [ "$secs" -lt 1 ] && secs=1
  printf '  %-22s %5s s   %4s MB/s\n' "$label" "$secs" "$(( MB / secs ))"
  printf '%s\n' "$secs" > "$WORK/secs.$3"
  rm -f "$point/durability-probe.bin" 2>/dev/null
  release
}

echo "$IMAGE, one ${MB} MB file, written with conv=fsync"
time_one "" "no option" plain
time_one "$OPTION" "-o $OPTION" option

# A verdict, so this can be a check rather than a reading somebody has to
# interpret.
#
# The option is not free and is not meant to be: without it a power cut takes
# 8 of 8 fsynced files and with it none, so half the throughput is the price of
# not losing the file and is worth paying. What must not happen is that price
# quietly growing -- an option that cost twice as much and came to cost ten
# times would look exactly like this from the outside.
#
# Three times, measured at two. The bound is where a change would have to be
# investigated, not where the current number sits, so ordinary variation on a
# busy Mac does not fail it.
plain_s="$(cat "$WORK/secs.plain" 2>/dev/null || echo 0)"
option_s="$(cat "$WORK/secs.option" 2>/dev/null || echo 0)"
echo
if [ "${plain_s:-0}" -lt 1 ] || [ "${option_s:-0}" -lt 1 ]; then
  echo "RESULT: one of the two writes did not happen; nothing to compare" >&2
  exit 1
fi
if [ "$option_s" -gt $(( plain_s * 3 )) ]; then
  echo "RESULT: -o $OPTION costs more than three times the write" >&2
  echo "        ${plain_s}s became ${option_s}s; it was measured at twice" >&2
  exit 1
fi
echo "RESULT: -o $OPTION costs ${option_s}s against ${plain_s}s, within the bound"
