#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Nothing this project makes is left loose in the temporary directory it shares
# with the rest of the Mac.
#
# WHY THIS RUNS RATHER THAN BEING READ
#
# The test suite checks that every script here sources the containment. That is
# a check on the text, and the text is not the thing: it would still pass if
# tmp-root.sh stopped exporting TMPDIR, if SwiftPM began writing somewhere it
# was not told to, or if a harness set TMPDIR back for a child. So this does the
# thing instead -- takes the names in the shared directory, builds, runs a
# script that makes a workspace, and takes the names again.
#
# What it caught the first time it ran: SwiftPM leaves eighteen
# TemporaryDirectory.XXXXXX behind on a single build. Fourteen thousand of them
# had collected before anybody looked.
set -uo pipefail

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="${LUKOTTA_TMP_ROOT%/lukotta-work}"

[ -d "$SHARED" ] || { echo "no shared temporary directory to watch" >&2; exit 2; }
[ "$SHARED" != "$LUKOTTA_TMP_ROOT" ] || { echo "containment did not take" >&2; exit 1; }

names() { find "$1" -maxdepth 1 -mindepth 1 2>/dev/null | sed 's|.*/||' | sort; }
before="$(names "$SHARED")"

# A build, because SwiftPM is the largest single source; and a workspace, because
# the harnesses are the largest by volume.
swift build --package-path "$HERE" --product Lukotta >/dev/null 2>&1
work="$(mktemp -d)"
: > "$work/app.log"

after="$(names "$SHARED")"
rm -rf "$work"

new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
# Everything else on this Mac goes on using this directory while we look, so a
# name that appeared is only ours if it is one of the shapes this project makes.
mine="$(printf '%s\n' "$new" | grep -E '^(TemporaryDirectory\.|tmp\.|lukotta-|Lukotta-)' || true)"

if [ -n "$mine" ]; then
  echo "left loose in $SHARED:"
  printf '%s\n' "$mine" | sed 's/^/  /'
  exit 1
fi

echo "nothing loose: a build and a workspace both landed in ${LUKOTTA_TMP_ROOT##*/}"
exit 0
