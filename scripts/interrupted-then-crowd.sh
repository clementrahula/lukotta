#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Twelve volumes killed mid-copy, then opened again.
#
# WHY
#
# Three copies onto one of twelve failed with "Stale NFS file handle". Eight
# runs on freshly formatted fixtures were clean, twelve for twelve every time,
# and every occurrence before them followed a run that had been killed
# mid-flight -- engines shot, images force-detached, nothing unmounted. That is
# how a volume is left dirty, and it is also exactly what a person does when
# they pull the cable out during a copy.
#
# So this does it on purpose: twelve opened, a copy started onto all of them,
# the machines killed and the images pulled with writes in the air, and then
# the twelve opened again and copied onto normally. If the stale handle is what
# an interrupted volume does on its next open, it appears here.
#
# The app is supposed to repair a volume left in that state -- item 7 -- so a
# stale handle on the next open is a repair that did not happen, or one that
# left the volume mountable but not sound.
#
#   ./scripts/interrupted-then-crowd.sh
#   ROUNDS=3 ./scripts/interrupted-then-crowd.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
ROUNDS="${ROUNDS:-2}"
OUT="${OUT:-$HOME/.lukotta-testvols}"

COPY="$(mktemp -d)"
trap 'rm -rf "$COPY"' EXIT
cp scripts/crowd-through-the-app.sh "$COPY/"

pull_the_cable() {
  # No unmount and no polite detach: the machines are shot where they stand and
  # the images are pulled with writes still in the air.
  pkill -9 -f crowd-through-the-app >/dev/null 2>&1
  pkill -9 -f 'anylinuxfs|krun|vmproxy' >/dev/null 2>&1
  for d in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}'); do
    hdiutil detach "$d" -force -quiet >/dev/null 2>&1
  done
  for p in $(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | sort -u); do
    umount -f "$p" >/dev/null 2>&1
  done
}

fail=0
for r in $(seq 1 "$ROUNDS"); do
  echo "########## round $r: interrupt ##########"
  bash "$COPY/crowd-through-the-app.sh" > "$COPY/int$r.log" 2>&1 &
  runner=$!
  killed=0
  for _ in $(seq 1 900); do
    if /usr/bin/grep -q 'wrote to' "$COPY/int$r.log" 2>/dev/null; then
      # The write has just finished on every volume, so the filesystems have
      # dirty metadata and no volume has been told anything. Pulled here.
      pull_the_cable; killed=1; break
    fi
    kill -0 "$runner" 2>/dev/null || break
    sleep 1
  done
  wait "$runner" 2>/dev/null
  if [ "$killed" != "1" ]; then
    echo "  the run finished before it could be interrupted" >&2
    fail=1; continue
  fi
  echo "  twelve pulled with writes in the air"
  sleep 3

  echo "########## round $r: open again ##########"
  bash "$COPY/crowd-through-the-app.sh" 2>&1 \
    | /usr/bin/grep -E 'could not be read|asked again|by name|room:|healed|no crowd-write|byte-identical|RESULT|copy onto|did not open'
done

echo
echo "logs of the interrupted rounds are in $COPY (removed on exit)"
exit "$fail"
