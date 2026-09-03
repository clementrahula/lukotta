#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The ten items, each tied to the check that proves it, run in one command.
#
# WHY THIS EXISTS
#
# On 2026-09-03 a fix for one fault quietly removed the repair from a rung and
# broke a volume Windows had left dirty -- item 7, which had been proven on
# 2026-09-01 and was still written down as proven. Nothing caught it. It was
# found because that item happened to have a harness and it happened to get run.
#
# Notes do not prevent that. Prose has to be re-read and believed by whoever
# comes next, and after a compaction or in a new session there is nobody left
# who remembers to. A command that runs and fails does not need to be believed.
#
# So this is the gate: every item that has a check, with the check named, and a
# line saying plainly which items are proven right now rather than which were
# proven once. Run it before a change and after one. What it prints is the
# answer to "is anything broken that used to work", which is the question that
# was not being asked.
#
#   ./scripts/verify-goal.sh              # the fast items
#   FULL=1 ./scripts/verify-goal.sh       # everything, tens of minutes
#   ONLY=7 ./scripts/verify-goal.sh       # one item
#
# Items with no check yet say so, in the same list, so a gap in the evidence is
# as visible as a failure. That is deliberate: an item nobody can check is not a
# item that passes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FULL="${FULL:-0}"
ONLY="${ONLY:-}"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

# Each item: number, what it claims, the command that proves it, and whether it
# is slow enough to need FULL=1.
run_item() {
  num="$1"; claim="$2"; slow="$3"; shift 3
  [ -n "$ONLY" ] && [ "$ONLY" != "$num" ] && return 0
  if [ "$#" -eq 0 ]; then
    printf '%2s  %-52s %s\n' "$num" "$claim" "NO CHECK YET" | tee -a "$RESULTS"
    return 0
  fi
  if [ "$slow" = "slow" ] && [ "$FULL" != "1" ] && [ -z "$ONLY" ]; then
    printf '%2s  %-52s %s\n' "$num" "$claim" "skipped, needs FULL=1" | tee -a "$RESULTS"
    return 0
  fi
  printf '%2s  %-52s ' "$num" "$claim"
  if "$@" > "$RESULTS.log" 2>&1; then
    printf 'PASS\n'; printf '%2s PASS\n' "$num" >> "$RESULTS"
  else
    printf 'FAIL\n'; printf '%2s FAIL\n' "$num" >> "$RESULTS"
    sed 's/^/      /' "$RESULTS.log" | tail -6
  fi
}

echo "the ten items, checked rather than remembered"
echo

run_item 1 "writing does not stall" slow
run_item 2 "no crash copying through Finder, both extremes" slow \
  bash scripts/finder-copy-cycles.sh
run_item 3 "nothing user-visible during a copy" slow \
  bash scripts/reused-record-interrupt.sh
run_item 4 "NTFS and BitLocker, byte-identical" slow \
  bash scripts/integrity-vectors.sh
run_item 5 "LUKS and the Linux filesystems inside it" slow
run_item 6 "every other format the app advertises" slow \
  bash scripts/vectors-every-format.sh
run_item 7 "a dirty NTFS volume is repaired, data intact" slow \
  bash scripts/dirty-ntfs-repair.sh
run_item 8 "a dozen volumes, 8 GB of pressure, still served" slow \
  bash scripts/twelve-under-pressure.sh
run_item 9 "integrity across every vector devised" slow \
  bash scripts/vectors-every-format.sh
run_item 10 "no UX cost anywhere in the above" fast \
  bash scripts/run-tests.sh

echo
# grep -c prints its zero and then exits 1, so "|| echo 0" appended a second
# zero and every one of these became the two-line string "0\n0" -- which [ ]
# rejects as not a number and exit refuses outright. The gate failed on its
# first run, in the arithmetic that decides whether anything failed. Left here
# with the note because it is the exact class of thing this script exists to
# catch, and it caught itself.
count_lines() { /usr/bin/grep -c "$1" "$RESULTS" 2>/dev/null | head -1 | tr -dc 0-9; }
passed=$(count_lines ' PASS$'); passed=${passed:-0}
failed=$(count_lines ' FAIL$'); failed=${failed:-0}
missing=$(count_lines 'NO CHECK YET'); missing=${missing:-0}
skipped=$(count_lines 'needs FULL=1'); skipped=${skipped:-0}
echo "proven now: $passed   failing: $failed   no check: $missing   not run: $skipped"
[ "$failed" -eq 0 ] || echo "SOMETHING THAT USED TO WORK DOES NOT" >&2
exit "$failed"
