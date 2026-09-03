#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive an interrupted copy poisoned is usable again after the app opens it.
#
# WHAT IT PROVES
#
# Pull a drive out during a copy and NTFS is left with a directory index entry
# whose MFT reference keeps a sequence the record has moved past. ntfs3 refuses
# it -- rightly; that check is what stops a handle resolving to whatever now
# occupies the record -- and ntfsfix does not repair it, because ntfsfix is not
# a chkdsk and there is no chkdsk here. Measured before the fix: the folder
# could not be read, deleted, or recreated, every later copy to that name failed
# with "Invalid argument" in the guest and "Stale NFS file handle" in Finder,
# and it stayed that way for ever.
#
# The app now moves such an entry aside as the volume comes up, under a name
# beginning with a dot so Finder does not show it, and the name is free again.
#
# WHY IT IS SEPARATE FROM reused-record-interrupt.sh
#
# That one makes the damage and asks the guest about it, which is the right
# tool for deciding whether a candidate fix helps. It cannot see this fix at
# all: the reclaim runs when the app opens the drive, and that harness never
# opens anything through the app. Registering it as the check for item 3 would
# have reported the fault as unfixed for ever.
#
#   ./scripts/reclaims-a-poisoned-name.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive2.img}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/crowd/$IMAGE"

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
strings -a "$APP" 2>/dev/null | /usr/bin/grep -q -- "--drive" || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

WORK="$(mktemp -d)"
DEV=""
clean_up() {
  for p in $(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force -quiet >/dev/null 2>&1
  rm -rf "$WORK"
}
trap clean_up EXIT
clean_up

echo "making the damage: a folder written, removed, written again, and cut"
timeout 200 "$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L RECLAIM /dev/vda" >/dev/null 2>&1
# shellcheck disable=SC2016
# Single quotes on purpose: every expansion in here belongs to the guest, not
# to this shell. Expanding them here would ask the Mac about paths inside a
# virtual machine, which is a different question with a plausible wrong answer.
timeout 400 "$ENGINE" shell "$IMG" -c '
  mkdir -p /mnt/x; mount -t ntfs3 /dev/vda /mnt/x || exit 1
  mkdir -p /mnt/x/big
  i=0; while [ $i -lt 300 ]; do i=$((i+1))
    head -c 4000 /dev/urandom > /mnt/x/big/f$i.bin 2>/dev/null || break; done
  rm -rf /mnt/x/big; sync
  mkdir -p /mnt/x/big; echo STARTED
  i=0; while [ $i -lt 40000 ]; do i=$((i+1))
    head -c 4000 /dev/urandom > /mnt/x/big/f$i.bin 2>/dev/null || break; done' \
  > "$WORK/damage.log" 2>&1 &
runner=$!
for _ in $(seq 1 240); do
  /usr/bin/grep -q STARTED "$WORK/damage.log" 2>/dev/null && break
  sleep 0.5
done
sleep 2
pkill -9 -f 'krun|anylinuxfs|vmproxy' >/dev/null 2>&1
wait "$runner" 2>/dev/null
sleep 3
if /usr/bin/grep -q FINISHED "$WORK/damage.log"; then
  echo "the write finished before the cut; nothing was interrupted" >&2
  exit 1
fi

echo "opening it through the app"
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "would not attach" >&2; exit 1; }
timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "the drive did not open: $(tail -1 "$WORK/open.log")" >&2; exit 1; }
POINT="$(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "opened and nothing is served" >&2; exit 1; }

echo "  root: $(find "$POINT" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>&1 | tr '\n' ' ')"

fail=0
if [ -e "$POINT/big" ]; then
  echo "the poisoned name is still there" >&2
  fail=1
fi
# Moved aside rather than destroyed, and hidden rather than left to be wondered
# about. Both matter: a repair that deletes somebody's folder is not a repair.
if ! find "$POINT" -maxdepth 1 -name '.lukotta-unreadable-*' 2>/dev/null \
  | /usr/bin/grep -q .; then
  echo "nothing was moved aside; what was there may have been destroyed" >&2
  fail=1
fi

echo "using the reclaimed name"
mkdir -p "$POINT/big" 2>/dev/null
written=0
for i in $(seq 1 20); do
  head -c 100000 /dev/urandom > "$POINT/big/f$i.bin" 2>/dev/null && written=$((written + 1))
done
back=$(find "$POINT/big" -type f 2>/dev/null | wc -l | tr -d ' ')
short=$(find "$POINT/big" -type f -size -100000c 2>/dev/null | wc -l | tr -d ' ')
echo "  $written written, $back read back, $short the wrong size"
[ "$written" -eq 20 ] && [ "$back" -eq 20 ] && [ "$short" -eq 0 ] || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: the name an interrupted copy poisoned is usable again"
else
  echo "RESULT: the drive is still not usable after an interrupted copy" >&2
fi
exit "$fail"
