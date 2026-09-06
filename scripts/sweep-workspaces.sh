#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Take away the workspaces killed runs left behind.
#
#   ./scripts/sweep-workspaces.sh          # anything older than three hours
#   HOURS=12 ./scripts/sweep-workspaces.sh
#
# WHY
#
# Every harness here makes a `mktemp -d` and removes it from a trap. A trap does
# not run when the run is killed -- and these runs are killed often, by a
# timeout, by a gate being stopped, by a machine being taken down mid-measure.
# What is left is not small: each workspace holds the payload the harness copied
# (a gigabyte in the copy tests), an image it duplicated so as not to spoil the
# fixture, or both.
#
# Counted on 2026-09-06, after a night of this: 208 workspaces under $TMPDIR,
# 7.6 GB, none of them belonging to anything running. Nobody had cleaned them
# because nobody owned them -- each harness cleans its own and none of them
# cleans another's.
#
# So this does, and the gate calls it before it starts. Three hours by default,
# which is longer than the longest single check, so a workspace belonging to a
# run in flight is never touched.
#
# WHAT IT WILL NOT REMOVE
#
# Only directories named `tmp.XXXXXXXX` directly under $TMPDIR, older than the
# bound, that carry something one of these harnesses made: a mount log, an
# engine log, a credential pipe, a witness file, a copied fixture. A `mktemp -d`
# belonging to anything else on the Mac has none of those and is left alone.
set -uo pipefail

HOURS="${HOURS:-3}"
MINUTES=$(( HOURS * 60 ))
TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"

# The marks a harness workspace carries. One is enough.
mine() {
  local dir="$1"
  for mark in mount.log engine.log discover.log credential.fifo witness.bin \
              witness.src big.bin filler.bin src.bin mount.sh discover.exp; do
    [ -e "$dir/$mark" ] && return 0
  done
  # A fixture copied so a run cannot spoil the original, and the payload trees
  # the copy tests build.
  for pattern in "$dir"/*.img "$dir"/payload "$dir"/power "$dir"/many "$dir"/few; do
    [ -e "$pattern" ] && return 0
  done
  return 1
}

freed=0
swept=0
for dir in "$TMP"/tmp.*; do
  [ -d "$dir" ] || continue
  # Older than the bound, so nothing in flight is touched.
  [ -n "$(find "$dir" -maxdepth 0 -mmin +"$MINUTES" 2>/dev/null)" ] || continue
  mine "$dir" || continue
  size="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
  rm -rf "$dir" 2>/dev/null || continue
  swept=$((swept + 1))
  freed=$((freed + ${size:-0}))
done

if [ "$swept" -gt 0 ]; then
  printf 'swept %d workspace(s) older than %d hours, %d MB\n' \
    "$swept" "$HOURS" "$(( freed / 1024 ))"
else
  printf 'no workspaces older than %d hours to sweep\n' "$HOURS"
fi
# Nothing to sweep is not a failure, and neither is a glob that matched
# nothing on the way here.
exit 0
