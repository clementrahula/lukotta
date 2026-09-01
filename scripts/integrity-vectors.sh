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
# Result on 2026-09-01, against a 64 MB NTFS fixture:
#
#   ok   a killed copy leaves no corrupt file behind (32 whole, 0 wrong)
#   ok   the volume still takes a write after a copy was killed
#   ok   the volume mounts and reads after being unmounted under load
#   ok   what was written before the unmount survived it
#   ok   a full volume answers with an error, in 1s
#   ok   three open/close cycles in a row
#
# The fixture ran out of space partway, which made the first case harsher than
# it was meant to be -- a copy killed on a volume that was already full -- and
# it still left nothing corrupt behind.
#
# Run again on a 2 GB ext4 image with permissions and concurrency added, all
# eight passing:
#
#   ok   a killed copy leaves no corrupt file behind (40 whole, 0 wrong)
#   ok   everything written is readable by whoever wrote it (3 of 3)
#   ok   two writers and a reader at once leave nothing wrong (24, 0 differing)
#
# The cycles case failed the first time at two of three, and that was this
# script being impatient rather than the app being wrong. Mounter.mount says
# it plainly: the machine keeps the image for another half-minute after the
# share goes, and opening the same file inside that window meets a locked file.
# The app waits for that. So does this now.
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

# This image's mount, and only this one. Another volume may be open -- the
# owner's drive usually is -- so the last engine mount in the table is somebody
# else's, and a mount whose machine has been killed stays there answering
# `mount` and failing every request. The engine names a share after the file it
# came from, so that is what to look for.
where() {
  mount | awk -v want="$(basename "$IMAGE" .img)-img.local:" \
    '$1 ~ want {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
}

open_image() {
  pkill -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1; sleep 3
  nohup "$ENGINE" mount --ignore-permissions -w false "$IMAGE" > "$WORK/engine.log" 2>&1 &
  # This image's share, not merely its name anywhere in the table: a stale
  # entry from a previous run carries the same name and answers nothing.
  for _ in $(seq 1 40); do
    [ -n "$(where)" ] && return 0
    sleep 2
  done
  return 1
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
# The machine keeps the image after the share goes. Mounter.mount says so:
# "An eject returns as soon as the volume leaves the mount table; the machine
# that served it keeps the image file for another half-minute, and opening the
# same file inside that window meets a locked file or a read-only mount nothing
# announced." The app waits for that; anything else driving the engine must too,
# and a harness that does not reports a failure to reopen that is its own
# impatience.
cycles=0
for _ in 1 2 3; do
  umount -f "$VOL" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    pgrep -f "anylinuxfs mount.*$(basename "$IMAGE")" >/dev/null 2>&1 || break
    sleep 2
  done
  if open_image; then VOL="$(where)"; [ -n "$VOL" ] && ls "$VOL" >/dev/null 2>&1 && cycles=$((cycles+1)); fi
done
note "$([ "$cycles" -eq 3 ] && echo ok || echo no)" "three open/close cycles in a row ($cycles of 3)"

# 7. Permissions. The export squashes who is asking and --ignore-permissions
#    makes everything appear as the person who opened the drive, which is the
#    point -- an NTFS volume has no idea what a uid is. What matters is that a
#    file written as read-only is still readable, that a directory can be
#    entered, and that nothing arrives inaccessible to the person who put it
#    there.
rm -rf "$VOL/vec-perms"; mkdir -p "$VOL/vec-perms"
printf 'readonly' > "$VOL/vec-perms/ro.txt" 2>/dev/null
chmod 444 "$VOL/vec-perms/ro.txt" 2>/dev/null
printf 'executable' > "$VOL/vec-perms/exe.sh" 2>/dev/null
chmod 755 "$VOL/vec-perms/exe.sh" 2>/dev/null
mkdir -p "$VOL/vec-perms/dir" 2>/dev/null
printf 'inside' > "$VOL/vec-perms/dir/f.txt" 2>/dev/null
readable=0
[ "$(cat "$VOL/vec-perms/ro.txt" 2>/dev/null)" = readonly ] && readable=$((readable + 1))
[ "$(cat "$VOL/vec-perms/exe.sh" 2>/dev/null)" = executable ] && readable=$((readable + 1))
[ "$(cat "$VOL/vec-perms/dir/f.txt" 2>/dev/null)" = inside ] && readable=$((readable + 1))
note "$([ "$readable" -eq 3 ] && echo ok || echo no)" \
  "everything written is readable by whoever wrote it ($readable of 3)"

# 8. Two writers and a reader at once. A copy is not the only thing touching a
#    drive -- Spotlight indexes it, Finder stats it, somebody opens a file from
#    it -- and the interesting question is whether concurrent work corrupts
#    anything rather than whether it is fast.
rm -rf "$VOL/vec-conc"; mkdir -p "$VOL/vec-conc/a" "$VOL/vec-conc/b"
payload "$WORK/conc" 12 300000
ditto "$WORK/conc" "$VOL/vec-conc/a" >/dev/null 2>&1 &
w1=$!
ditto "$WORK/conc" "$VOL/vec-conc/b" >/dev/null 2>&1 &
w2=$!
( for _ in $(seq 1 40); do cat "$VOL"/vec-perms/* >/dev/null 2>&1; sleep 0.25; done ) &
r1=$!
wait "$w1" 2>/dev/null; wait "$w2" 2>/dev/null; kill "$r1" 2>/dev/null
cbad=0; cn=0
for side in a b; do
  while IFS= read -r f; do
    rel="${f#"$WORK/conc"/}"; cn=$((cn + 1))
    cmp -s "$f" "$VOL/vec-conc/$side/$rel" || cbad=$((cbad + 1))
  done < <(find "$WORK/conc" -type f)
done
note "$([ "$cbad" -eq 0 ] && echo ok || echo no)" \
  "two writers and a reader at once leave nothing wrong ($cn compared, $cbad differing)"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
