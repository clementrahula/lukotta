#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Take this project's test data off a drive, and nothing else.
#
#   ./scripts/sweep-drive.sh /Volumes/SOMETHING
#
# WHY
#
# The harnesses here write dummy payloads onto real drives -- eight megabytes
# of urandom for a durability run, four hundred for a copy timing, two thousand
# small files for a Finder cycle -- and remove them from a trap. A trap does not
# run when the run is killed, and these runs are killed often.
#
# Found on 2026-09-06 on the owner's exFAT stick: `lukotta-cost-23699` and
# `lukotta-durability-94333`, 84 MB, belonging to runs that had ended hours
# earlier. `with-a-drive-open.sh` sweeps a drive it opens, and the harnesses
# that open a drive themselves swept nothing, so nobody owned these.
#
# WHAT IT WILL NOT REMOVE
#
# Only the names this project creates. The list is explicit and it is not a
# pattern anybody's own files can fall into: every harness here names its work
# `lukotta-*`, `vec-*`, `copyvis*`, `crowd-write` or `.lukotta-unreadable-*`.
# Anything else on the drive was put there by whoever owns it -- these drives
# include somebody's backups -- and is not this script's to touch.
set -uo pipefail

POINT="${1:-}"
[ -n "$POINT" ] || { echo "usage: $0 <mount point>" >&2; exit 2; }
[ -d "$POINT" ] || { echo "error: no directory at $POINT" >&2; exit 2; }

# A mount point, never the root of anything. An empty or short path here would
# turn the loop below into a sweep of somewhere that matters.
case "$POINT" in
  /|/Users|/Users/*|/System*|/Applications*|/Library*)
    echo "error: $POINT is not a drive this may sweep" >&2; exit 2 ;;
esac

shopt -s nullglob
removed=0
freed=0
for item in "$POINT"/lukotta-* "$POINT"/vec-* "$POINT"/copyvis* \
            "$POINT"/crowd-write "$POINT"/.lukotta-unreadable-*; do
  size="$(du -sk "$item" 2>/dev/null | awk '{print $1}')"
  rm -rf "$item" 2>/dev/null || continue
  removed=$((removed + 1))
  freed=$((freed + ${size:-0}))
done

if [ "$removed" -gt 0 ]; then
  printf 'took %d leftover(s) off %s, %d MB\n' "$removed" "$POINT" "$(( freed / 1024 ))"
else
  printf 'nothing of this project'"'"'s left on %s\n' "$POINT"
fi
exit 0
