#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Empty the directory this project's temporary things go in.
#
#   ./scripts/sweep-workspaces.sh          # anything older than three hours
#   HOURS=12 ./scripts/sweep-workspaces.sh
#
# WHY
#
# Every harness here makes a workspace and removes it from a trap. A trap does
# not run when the run is killed -- and these runs are killed often, by a
# timeout, by a gate being stopped, by a machine being taken down mid-measure.
# What is left is not small: each workspace holds the payload the harness copied
# (a gigabyte in the copy tests), an image it duplicated so as not to spoil the
# fixture, or both.
#
# WHY IT NO LONGER GUESSES
#
# This used to look at every `tmp.XXXXXXXX` in the shared $TMPDIR and decide,
# from a list of marker filenames, which ones were ours. That was the wrong
# shape and it did not work. Measured on 2026-09-08 against 108 stale
# workspaces: it recognised **one**. The other 107 held 1.65 GB and were plainly
# this project's -- app.log, full.err, mnt, src, dittoCROWD*.log, before.sums --
# and not one of those names was in the list. The list could have been extended
# again, and the next harness to write a new filename would have escaped it
# again, because a deleter that guesses at names it does not control is wrong by
# construction. Worse, being generous with the guesses is how such a sweep
# eventually deletes somebody else's data out of a directory shared with the
# whole Mac.
#
# So the guessing is gone. `scripts/tmp-root.sh` moves $TMPDIR itself into one
# directory this project owns, before anything below it runs, and every child
# inherits it -- every mktemp, every `swift build`, every NSTemporaryDirectory()
# in the app the harnesses drive. Nothing else on the Mac writes there. This
# empties it by age, and cannot be wrong about whose it was.
set -uo pipefail

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"

HOURS="${HOURS:-3}"
MINUTES=$(( HOURS * 60 ))
ROOT="${LUKOTTA_TMP_ROOT:-}"

# The one thing that must never happen. If containment did not take -- an
# unwritable $TMPDIR, someone exporting LUKOTTA_TMP_ROOT by hand -- this points
# at a directory shared with the whole Mac, and a sweep by age would take other
# people's work with it. Refuse rather than widen.
case "$ROOT" in
  ""|"/"|"/tmp"|"/var/tmp") echo "refusing to sweep '$ROOT'" >&2; exit 0 ;;
esac
[ "${ROOT##*/}" = "lukotta-work" ] || { echo "refusing to sweep '$ROOT'" >&2; exit 0; }
[ -d "$ROOT" ] || { printf 'nothing to sweep\n'; exit 0; }

freed=0
swept=0
for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  [ -e "$entry" ] || continue
  # Older than the bound, so nothing in flight is touched. Three hours by
  # default, which is longer than the longest single check.
  [ -n "$(find "$entry" -maxdepth 0 -mmin +"$MINUTES" 2>/dev/null)" ] || continue
  size="$(du -sk "$entry" 2>/dev/null | awk '{print $1}')"
  rm -rf "$entry" 2>/dev/null || continue
  swept=$((swept + 1))
  freed=$((freed + ${size:-0}))
done

if [ "$swept" -gt 0 ]; then
  printf 'swept %d thing(s) older than %d hours, %d MB\n' \
    "$swept" "$HOURS" "$(( freed / 1024 ))"
else
  printf 'nothing older than %d hours to sweep\n' "$HOURS"
fi
# Nothing to sweep is not a failure, and neither is a glob that matched
# nothing on the way here.
exit 0
