#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The tightest statement of the fault: a reused MFT record, then a cut.
#
# WHAT IT REPRODUCES
#
# A folder is written, deleted, and written again -- so the new entries land on
# MFT records the delete has just freed -- and the machine is cut down two
# seconds into the second write. On the next open the folder cannot be read,
# cannot be deleted and cannot be recreated: `Invalid argument` inside the
# guest, errno 70 and "Stale NFS file handle" by the time it reaches Finder.
#
# WHY IT EXISTS
#
# The same fault appears through the twelve-volume harness about one run in
# six, and each of those runs costs five minutes to reach the copy. This is
# ninety seconds and it has not missed yet. Anything proposed as a fix is cheap
# to try against it, which is how two were already tried and rejected: serving
# the repaired volume with ntfs-3g moved the errno from EINVAL to EIO and cured
# nothing, and mounting the volume `-o sync` made no difference at all.
#
# WHY THE DELETE MATTERS. Without it the cut leaves no damage: the half-made
# folder is simply not there afterwards, which is what an interrupted copy
# should look like. The damage needs a record that has been freed and reused,
# because what breaks is the directory index entry keeping the old sequence
# number while the record moves on -- and the sequence check is precisely what
# stops a stale handle resolving to whatever now occupies the record. ntfs3 is
# right to refuse it. Nothing on Linux replays the NTFS journal, and ntfsfix is
# not a chkdsk, so nothing puts it back.
#
#   ./scripts/reused-record-interrupt.sh
#   MOUNT_OPTS='-o sync' ./scripts/reused-record-interrupt.sh
#   ROUNDS=3 IMAGE=drive3.img ./scripts/reused-record-interrupt.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive2.img}"
ROUNDS="${ROUNDS:-2}"
CUT_AFTER="${CUT_AFTER:-2}"
MOUNT_OPTS="${MOUNT_OPTS:-}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
IMG="$OUT/crowd/$IMAGE"

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
if hdiutil info 2>/dev/null | /usr/bin/grep -q "$IMG"; then
  echo "error: $IMAGE is attached; detach it first" >&2; exit 2
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "$ROUNDS rounds on $IMAGE, cut ${CUT_AFTER}s into the second write"
[ -n "$MOUNT_OPTS" ] && echo "  guest mount options: $MOUNT_OPTS"

broken=0
for r in $(seq 1 "$ROUNDS"); do
  timeout 200 "$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L T /dev/vda" >/dev/null 2>&1
  : > "$LOG"
  timeout 400 "$ENGINE" shell "$IMG" -c "
    mkdir -p /mnt/x; mount -t ntfs3 $MOUNT_OPTS /dev/vda /mnt/x || exit 1
    mkdir -p /mnt/x/big
    i=0; while [ \$i -lt 300 ]; do i=\$((i+1))
      head -c 4000 /dev/urandom > /mnt/x/big/f\$i.bin 2>/dev/null || break; done
    rm -rf /mnt/x/big; sync
    mkdir -p /mnt/x/big; echo STARTED
    i=0; while [ \$i -lt 40000 ]; do i=\$((i+1))
      head -c 4000 /dev/urandom > /mnt/x/big/f\$i.bin 2>/dev/null || break; done
    echo FINISHED" > "$LOG" 2>&1 &
  runner=$!
  for _ in $(seq 1 240); do
    /usr/bin/grep -q STARTED "$LOG" 2>/dev/null && break
    sleep 0.5
  done
  sleep "$CUT_AFTER"
  pkill -9 -f 'krun|anylinuxfs|vmproxy' >/dev/null 2>&1
  wait "$runner" 2>/dev/null
  sleep 3

  if /usr/bin/grep -q FINISHED "$LOG"; then
    echo "  round $r: the write finished before the cut; nothing was interrupted" >&2
    continue
  fi

  # shellcheck disable=SC2016
  # Single quotes on purpose: everything in here is for the guest to expand,
  # not this shell. Expanding $(ls ...) on the Mac would ask the Mac about a
  # path inside a virtual machine, which is a different question with a
  # plausible-looking wrong answer.
  verdict="$(timeout 300 "$ENGINE" shell "$IMG" -c '
    ntfsfix -d /dev/vda >/dev/null 2>&1
    mkdir -p /mnt/x; dmesg -c >/dev/null 2>&1
    mount -t ntfs3 /dev/vda /mnt/x >/dev/null 2>&1 || { echo "VERDICT will not mount"; exit; }
    if ls /mnt/x/big >/dev/null 2>&1; then
      if touch /mnt/x/big/after 2>/dev/null; then echo "VERDICT usable"
      else echo "VERDICT readable but nothing can be written into it"; fi
    elif [ -e /mnt/x/big ]; then
      echo "VERDICT broken: $(ls /mnt/x/big 2>&1 | head -1 | sed "s/.*: //")"
    elif mkdir /mnt/x/big 2>/dev/null; then echo "VERDICT gone, and the name is free again"
    else echo "VERDICT gone, and the name is poisoned"; fi' 2>&1 \
    | /usr/bin/grep '^VERDICT' | sed 's/^VERDICT //')"
  echo "  round $r: ${verdict:-no answer}"
  case "$verdict" in
    usable|"gone, and the name is free again") ;;
    *) broken=$((broken + 1)) ;;
  esac
done

echo
if [ "$broken" -eq 0 ]; then
  echo "RESULT: an interrupted copy left every volume usable"
else
  echo "RESULT: $broken of $ROUNDS left a folder that cannot be used" >&2
  exit 1
fi
