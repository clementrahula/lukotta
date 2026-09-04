#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The checker frees a name an interrupted copy poisoned.
#
# WHAT IT PROVES
#
# reused-record-interrupt.sh makes the damage and stops there: a directory
# index entry whose MFT reference keeps a sequence the record has moved past.
# The name then refuses ls, stat, mv, rm and mkdir alike, under both drivers,
# for good -- ntfsfix does not touch it, because ntfsfix is not a chkdsk.
#
# This one makes the same damage, asks the guest what state the volume is in,
# runs ntfsck over the unmounted device, and asks again. A pass needs both
# halves: damaged before, working after. A round that comes back undamaged is
# discarded rather than counted -- a clean volume staying clean says the tool
# ran, not that it repairs, and counting those would let this report success on
# a build with no checker in it at all.
#
#   ./scripts/ntfsck-repairs.sh
#   ROUNDS=3 ./scripts/ntfsck-repairs.sh
set -uo pipefail

OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-drive2.img}"
ROUNDS="${ROUNDS:-2}"
CUT_AFTER="${CUT_AFTER:-2}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
IMG="$OUT/crowd/$IMAGE"

# The guest the app ships, not the one the engine keeps for itself.
#
# `anylinuxfs shell` with nothing set uses ~/.anylinuxfs, which is the shared
# home the command-line engine unpacks for its own use. The app never boots
# that one: it hands the engine ANYLINUXFS_HOME pointing inside its own
# Application Support directory, and unpacks the rootfs from its bundle there.
# Asking the shared home whether ntfsck exists answers a question about a guest
# no user ever runs -- and it answered "no" while the app's own guest had it.
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)"
[ -n "$APP_ID" ] || { echo "error: no bundle identifier for $APP_BUNDLE" >&2; exit 2; }
ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
export ANYLINUXFS_HOME
[ -d "$ANYLINUXFS_HOME/.anylinuxfs/alpine/rootfs" ] || {
  echo "error: $APP_ID has not unpacked its guest yet; open a drive with it once" >&2
  exit 2; }

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
[ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
if hdiutil info 2>/dev/null | /usr/bin/grep -q "$IMG"; then
  echo "error: $IMAGE is attached; detach it first" >&2; exit 2
fi

# The prerequisite, asserted before anything is measured. Without this the
# script still runs, every repair silently does nothing, and the failure reads
# as "ntfsck does not work" rather than "there is no ntfsck here".
have="$(timeout 300 "$ENGINE" shell "$IMG" -c 'command -v ntfsck || echo NONE' 2>&1 \
  | /usr/bin/grep -E '^(/|NONE)' | head -1)"
case "$have" in
  /*) echo "checker: $have" ;;
  *)  echo "error: the guest carries no ntfsck -- run scripts/build-ntfsck.sh," >&2
      echo "       then scripts/vendor-engine.sh and rebuild the app" >&2
      exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# What state the volume is in, asked from inside the guest.
#
# Single quotes throughout: every expansion belongs to the guest. Expanding
# them here would ask the Mac about paths inside a virtual machine, which is a
# different question with a plausible wrong answer.
probe() {
  # shellcheck disable=SC2016
  timeout 300 "$ENGINE" shell "$IMG" -c '
    mkdir -p /mnt/x
    mount -t ntfs3 /dev/vda /mnt/x >/dev/null 2>&1 || { echo "STATE will not mount"; exit; }
    if ls /mnt/x/big >/dev/null 2>&1; then
      if touch /mnt/x/big/after 2>/dev/null; then echo "STATE usable"
      else echo "STATE readable but nothing can be written into it"; fi
    elif [ -e /mnt/x/big ]; then
      echo "STATE broken: $(ls /mnt/x/big 2>&1 | head -1 | sed "s/.*: //")"
    elif mkdir /mnt/x/big 2>/dev/null; then echo "STATE free"
    else echo "STATE poisoned"; fi
    umount /mnt/x >/dev/null 2>&1' 2>&1 \
    | /usr/bin/grep '^STATE' | sed 's/^STATE //' | head -1
}

is_good() { case "$1" in usable|free) return 0 ;; *) return 1 ;; esac; }

echo "$ROUNDS rounds on $IMAGE, cut ${CUT_AFTER}s into the second write"
damaged=0; repaired=0; discarded=0
for r in $(seq 1 "$ROUNDS"); do
  timeout 200 "$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L CHECK /dev/vda" >/dev/null 2>&1
  : > "$WORK/damage.log"
  # shellcheck disable=SC2016
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
    echo "  round $r: the write finished before the cut; discarded"
    discarded=$((discarded + 1)); continue
  fi

  before="$(probe)"
  echo "  round $r: before  ${before:-no answer}"
  if is_good "$before"; then
    echo "           the cut left nothing damaged; discarded"
    discarded=$((discarded + 1)); continue
  fi
  damaged=$((damaged + 1))

  # Passes, not a pass.
  #
  # One run of `ntfsck -a` does not finish the job and does not claim to. On
  # the first pass over an interrupted copy it declines its own mass-free --
  # "MFT scan is too unreliable to free a large number of clusters, refusing
  # mass-free and marking them in-use instead" -- and ends with errors left and
  # the dirty flag still set, which is a volume ntfs3 will not mount at all.
  # The second pass, with the structure now consistent, applies the bitmap
  # update it refused and reports Clean; the third confirms it. Measured: 5193
  # of 5199 fixed on pass one, the last one on pass two.
  #
  # So the loop runs until it says Clean, up to a bound. Stopping at one pass
  # reads as "ntfsck cannot repair this" while the repair is one more pass away.
  # shellcheck disable=SC2016
  timeout 1800 "$ENGINE" shell "$IMG" -c '
    n=0
    while [ $n -lt 4 ]; do
      n=$((n+1))
      out="$(ntfsck -a /dev/vda 2>&1 | tail -1)"
      echo "PASS $n $out"
      case "$out" in Clean,*) break ;; esac
    done' > "$WORK/ntfsck.log" 2>&1
  /usr/bin/grep '^PASS' "$WORK/ntfsck.log" | while IFS= read -r line; do
    echo "           $line"
  done

  after="$(probe)"
  echo "  round $r: after   ${after:-no answer}"
  is_good "$after" && repaired=$((repaired + 1))
done

echo
if [ "$damaged" -eq 0 ]; then
  echo "RESULT: no round produced damage, so nothing was tested ($discarded discarded)" >&2
  exit 1
fi
if [ "$repaired" -eq "$damaged" ]; then
  echo "RESULT: ntfsck freed the poisoned name in $repaired of $damaged damaged rounds"
else
  echo "RESULT: ntfsck freed $repaired of $damaged damaged rounds" >&2
  exit 1
fi
