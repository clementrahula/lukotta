#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive an interrupted copy damaged opens writable, through the app.
#
# WHAT IT PROVES
#
# ntfsck-repairs.sh proves the checker repairs, by driving the guest directly.
# That is the right instrument for deciding whether ntfsck can do the job and
# the wrong one for deciding whether anybody gets it: the repair runs on a rung
# of the mount ladder, generated into the engine's config, reached only after a
# writable mount has already failed. None of that is exercised by a shell into
# the guest.
#
# So this one damages a volume and then opens it the way a person does, and
# asks the only question that matters afterwards: did the drive come up
# writable, and can the folder be used. Before the checker, the same volume was
# handed back read-only -- the dry run that gated the repair does not print
# "completed successfully" for damage beyond a dirty flag, so the rung refused
# it and the ladder fell through to read-only. That is the result this replaces.
#
#   ./scripts/repairs-through-the-app.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive2.img}"
CUT_AFTER="${CUT_AFTER:-2}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/crowd/$IMAGE"

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
# grep -c, not grep -q: under pipefail a -q match exits at once, strings dies of
# SIGPIPE, and the check refuses every bundle that is fine.
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

# The guest the app boots, asserted before anything is measured: without the
# checker the repair silently falls back and this reads as a fault in the rung.
APP_ID="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)"
HOME_DIR="$HOME/Library/Application Support/$APP_ID/engine/.anylinuxfs/alpine/rootfs"
[ -x "$HOME_DIR/usr/sbin/ntfsck" ] || {
  echo "error: the guest $APP_ID boots carries no ntfsck" >&2
  echo "       ($HOME_DIR)" >&2; exit 2; }

WORK="$(mktemp -d)"
DEV=""
release_drives() {
  for p in $(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  [ -n "${DEV:-}" ] && hdiutil detach "$DEV" -force -quiet >/dev/null 2>&1
  for d in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}'); do
    hdiutil detach "$d" -force -quiet >/dev/null 2>&1
  done
  DEV=""
}
clean_up() { release_drives; rm -rf "$WORK"; }
trap clean_up EXIT
release_drives

echo "making the damage: a folder written, removed, written again, and cut"
timeout 200 "$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L REPAIR /dev/vda" >/dev/null 2>&1
# shellcheck disable=SC2016
# Single quotes on purpose: every expansion belongs to the guest, not to this
# shell. Expanding them here asks the Mac about paths inside a virtual machine.
timeout 400 "$ENGINE" shell "$IMG" -c '
  mkdir -p /mnt/x; mount -t ntfs3 /dev/vda /mnt/x || exit 1
  mkdir -p /mnt/x/big
  i=0; while [ $i -lt 300 ]; do i=$((i+1))
    head -c 4000 /dev/urandom > /mnt/x/big/f$i.bin 2>/dev/null || break; done
  rm -rf /mnt/x/big; sync
  mkdir -p /mnt/x/big; echo STARTED
  i=0; while [ $i -lt 40000 ]; do i=$((i+1))
    head -c 4000 /dev/urandom > /mnt/x/big/f$i.bin 2>/dev/null || break; done
  echo FINISHED' > "$WORK/damage.log" 2>&1 &
runner=$!
for _ in $(seq 1 240); do
  /usr/bin/grep -q STARTED "$WORK/damage.log" 2>/dev/null && break
  sleep 0.5
done
sleep "$CUT_AFTER"
pkill -9 -f 'krun|anylinuxfs|vmproxy' >/dev/null 2>&1
wait "$runner" 2>/dev/null
sleep 3
if /usr/bin/grep -q FINISHED "$WORK/damage.log"; then
  echo "the write finished before the cut; nothing was interrupted" >&2
  exit 1
fi

# The damage is real, established before the app is given a chance to fix it.
# Without this a run where the cut did nothing reports a successful repair.
# shellcheck disable=SC2016
before="$(timeout 300 "$ENGINE" shell "$IMG" -c '
  mkdir -p /mnt/x
  mount -t ntfs3 /dev/vda /mnt/x >/dev/null 2>&1 || { echo "STATE will not mount"; exit; }
  if ls /mnt/x/big >/dev/null 2>&1; then echo "STATE usable"; else echo "STATE broken"; fi
  umount /mnt/x >/dev/null 2>&1' 2>&1 | /usr/bin/grep '^STATE' | sed 's/^STATE //' | head -1)"
echo "  before the app: ${before:-no answer}"
if [ "$before" = "usable" ]; then
  echo "the cut left nothing damaged; nothing was tested" >&2
  exit 1
fi

echo "opening it through the app"
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "would not attach" >&2; exit 1; }
timeout 900 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "the drive did not open: $(tail -2 "$WORK/open.log")" >&2; exit 1; }

SHARE="$(basename "$DEV").local:"
POINT="$(mount | /usr/bin/grep -F "$SHARE" | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "opened and nothing is served" >&2; exit 1; }
echo "  served at $POINT"
echo "  root: $(find "$POINT" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>&1 | tr '\n' ' ')"

# Read-only would be the old answer, and it is not the one being asked for.
if mount | /usr/bin/grep -F "$SHARE" | /usr/bin/grep -q 'read-only'; then
  echo "RESULT: the drive was handed back read-only, which is the fault, not the fix" >&2
  exit 1
fi

fault=""
if ! ls "$POINT/big" >/dev/null 2>&1; then
  mkdir "$POINT/big" 2>/dev/null || fault="the name is still poisoned"
fi
if [ -z "$fault" ]; then
  head -c 4096 /dev/urandom > "$POINT/big/written-after-repair.bin" 2>"$WORK/write.err" \
    || fault="nothing can be written into it: $(head -1 "$WORK/write.err")"
fi
if [ -z "$fault" ] && [ "$(wc -c < "$POINT/big/written-after-repair.bin" 2>/dev/null || echo 0)" -ne 4096 ]; then
  fault="the file written into it did not arrive whole"
fi

if [ -n "$fault" ]; then
  echo
  echo "RESULT: opened writable and $fault" >&2
  exit 1
fi
echo "  repaired: opened writable, and the folder took a file"

# And a volume with nothing wrong is not scanned.
#
# The other half of the same claim, and the half that is easy to lose: a check
# reads the whole MFT -- 59 seconds on a 247 GB drive -- so a rule that checks
# whenever it might help would charge every healthy drive for the few damaged
# ones. The evidence is durable and on the volume: the check writes
# .lukotta-check.log wherever it runs, on failure as well as success, so a
# healthy volume that has one has been scanned for nothing.
echo
echo "the same drive again, now that it is repaired"
release_drives
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "would not attach the second time" >&2; exit 1; }
timeout 900 "$APP" --drive open="$DEV" > "$WORK/open2.log" 2>&1 \
  || { echo "the repaired drive did not open: $(tail -2 "$WORK/open2.log")" >&2; exit 1; }
SHARE="$(basename "$DEV").local:"
POINT="$(mount | /usr/bin/grep -F "$SHARE" | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "the repaired drive opened and nothing is served" >&2; exit 1; }
rm -f "$POINT/.lukotta-check.log" 2>/dev/null
release_drives
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "would not attach the third time" >&2; exit 1; }
timeout 900 "$APP" --drive open="$DEV" > "$WORK/open3.log" 2>&1 \
  || { echo "the healthy drive did not open: $(tail -2 "$WORK/open3.log")" >&2; exit 1; }
SHARE="$(basename "$DEV").local:"
POINT="$(mount | /usr/bin/grep -F "$SHARE" | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "the healthy drive opened and nothing is served" >&2; exit 1; }

echo
if [ -e "$POINT/.lukotta-check.log" ]; then
  echo "RESULT: a volume with nothing wrong was scanned anyway" >&2
  exit 1
fi
echo "RESULT: a volume that would not mount opened writable and took a file;"
echo "        the same volume, repaired, was opened again and not scanned"
