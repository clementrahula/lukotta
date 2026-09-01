#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The vectors a copy is not supposed to survive, run against a fixture.
#
#   ./scripts/integrity-vectors.sh <image> [engine]
#
# A copy that completes twice says nothing about what happens when it does
# not. These are the ways it does not: killed partway, unmounted underneath,
# run into a full volume, and the same volume opened and closed repeatedly.
# What is checked afterwards is not "did the copy finish" -- it did not, that
# is the point -- but whether the filesystem is still sound and whether the
# files that had already landed are still exactly themselves.
#
# Deliberately a fixture and never a real drive. Force-unmounting a volume
# mid-write is the operation most likely to damage it, and the drive somebody
# keeps their photographs on is not the place to find out. The image is made by
# make-format-volumes.sh or make-test-volumes.sh and holds nothing anybody
# needs.
set -uo pipefail

IMAGE="${1:-}"
ENGINE="${2:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -f "$IMAGE" ] || { echo "usage: $0 <image> [engine]" >&2; exit 2; }
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }

APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"

WORK="$(mktemp -d)"
MNT="$WORK/mnt"; mkdir -p "$MNT"
trap 'cleanup' EXIT
cleanup() {
  umount -f "$MNT" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1
  rm -rf "$WORK"
}

open_image() {
  pkill -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1; sleep 3
  nohup "$ENGINE" mount --ignore-permissions -w false "$IMAGE" > "$WORK/engine.log" 2>&1 &
  for _ in $(seq 1 40); do
    mount | grep -q "$(basename "$IMAGE" .img)" && return 0
    sleep 2
  done
  return 1
}

# Where the engine put it. Unelevated mounts land under ~/Volumes, elevated
# ones under /Volumes, and which happened is not worth guessing at.
where() {
  mount | awk '/anylinuxfs|172\.27/ {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | tail -1
}

pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2";
         else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi }

payload() {  # directory, count, size-bytes
  mkdir -p "$1"
  for i in $(seq 1 "$2"); do head -c "$3" /dev/urandom > "$1/f$i.bin"; done
}

echo "opening $IMAGE"
open_image || { echo "error: the engine never mounted it; see $WORK/engine.log" >&2; exit 1; }
VOL="$(where)"
[ -n "$VOL" ] || { echo "error: mounted, but nowhere findable" >&2; exit 1; }
echo "mounted at $VOL"

SRC="$WORK/src"; payload "$SRC" 40 2000000     # 80 MB, enough to interrupt

# 1. A copy killed partway. What landed before the knife must still be itself.
rm -rf "$VOL/vec-interrupted"; mkdir -p "$VOL/vec-interrupted"
ditto "$SRC" "$VOL/vec-interrupted" & dpid=$!
sleep 4; kill -9 "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
intact=0; broken=0
for f in "$VOL/vec-interrupted"/*.bin; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  # Only files that finished are claimed; a half-written one is expected.
  if [ "$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")" = "2000000" ]; then
    if cmp -s "$SRC/$n" "$f"; then intact=$((intact+1)); else broken=$((broken+1)); fi
  fi
done
note "$([ "$broken" -eq 0 ] && echo ok || echo no)" \
  "a killed copy leaves no corrupt file behind ($intact whole, $broken wrong)"

# 2. The volume still works afterwards, which is the part that matters.
if printf 'after' > "$VOL/vec-after-kill" 2>/dev/null && [ "$(cat "$VOL/vec-after-kill" 2>/dev/null)" = after ]; then
  note ok "the volume still takes a write after a copy was killed"
else
  note no "the volume still takes a write after a copy was killed"
fi

# 3. Unmounted from underneath a running copy, then opened again.
rm -rf "$VOL/vec-yanked"; mkdir -p "$VOL/vec-yanked"
ditto "$SRC" "$VOL/vec-yanked" >/dev/null 2>&1 & dpid=$!
sleep 3
umount -f "$VOL" >/dev/null 2>&1
kill -9 "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
if open_image; then
  VOL="$(where)"
  if [ -n "$VOL" ] && [ -d "$VOL" ] && ls "$VOL" >/dev/null 2>&1; then
    note ok "the volume mounts and reads after being unmounted under load"
  else
    note no "the volume mounts and reads after being unmounted under load"
  fi
else
  note no "the volume mounts and reads after being unmounted under load"
fi

# 4. Files written before all that are still exactly themselves.
if [ -n "$VOL" ] && [ -f "$VOL/vec-after-kill" ] && [ "$(cat "$VOL/vec-after-kill" 2>/dev/null)" = after ]; then
  note ok "what was written before the unmount survived it"
else
  note no "what was written before the unmount survived it"
fi

# 5. Run it out of space. ENOSPC is an answer; a hang is not.
rm -rf "$VOL/vec-full"; mkdir -p "$VOL/vec-full"
start=$(date +%s)
timeout 300 dd if=/dev/zero of="$VOL/vec-full/filler.bin" bs=1048576 status=none 2>"$WORK/full.err"
rc=$?; elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 124 ]; then
  note no "a full volume answers rather than hanging (still going after ${elapsed}s)"
elif grep -qiE 'no space|full' "$WORK/full.err" 2>/dev/null || [ "$rc" != 0 ]; then
  note ok "a full volume answers with an error, in ${elapsed}s"
else
  note no "a full volume answers with an error (dd claimed success)"
fi
rm -f "$VOL/vec-full/filler.bin"

# 6. Opened and closed repeatedly, which is what a person does over a week.
cycles=0
for _ in 1 2 3; do
  umount -f "$VOL" >/dev/null 2>&1
  if open_image; then VOL="$(where)"; [ -n "$VOL" ] && ls "$VOL" >/dev/null 2>&1 && cycles=$((cycles+1)); fi
done
note "$([ "$cycles" -eq 3 ] && echo ok || echo no)" "three open/close cycles in a row ($cycles of 3)"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
