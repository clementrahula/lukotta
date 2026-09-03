#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Runs the claims in checks.tsv and says which of them hold right now.
#
# WHY
#
# A fix for one fault quietly removed the repair from a mount rung and broke a
# behaviour proven weeks earlier and still written down as proven. Nothing
# caught it: the record was prose, and prose has to be re-read and believed by
# whoever comes next. After a compaction, or in a new session, nobody is left
# who remembers to.
#
# This does not need to be believed. It runs, and a claim that no longer holds
# fails out loud with the check named.
#
#   ./scripts/verify.sh                  # every fast claim
#   FULL=1 ./scripts/verify.sh           # everything, tens of minutes
#   TAG=release ./scripts/verify.sh      # one set
#   ID=goal7 ./scripts/verify.sh         # one claim, slow or not
#
# It is deliberately not about any particular list of goals. checks.tsv is a
# registry: a task that proves something adds a row and it is checked from then
# on, whatever it was about.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
FULL="${FULL:-0}"
TAG="${TAG:-}"
ID="${ID:-}"
LIST="${CHECKS:-scripts/checks.tsv}"
[ -f "$LIST" ] || { echo "error: no $LIST" >&2; exit 2; }

LOG="$(mktemp)"; TALLY="$(mktemp)"
trap 'rm -f "$LOG" "$TALLY"' EXIT

printf '%-10s %-52s %s\n' claim what result
echo

while IFS=$'\t' read -r id tags speed claim cmd; do
  case "$id" in ''|\#*) continue;; esac
  [ -n "$ID" ] && [ "$ID" != "$id" ] && continue
  if [ -n "$TAG" ]; then
    case ",$tags," in *",$TAG,"*) ;; *) continue;; esac
  fi

  # A claim with no check is shown as unchecked rather than left out. An
  # unchecked claim is not a claim that passes, and hiding it is how prose
  # started being trusted in the first place.
  if [ -z "${cmd:-}" ]; then
    printf '%-10s %-52s %s\n' "$id" "$claim" "NO CHECK"
    echo unchecked >> "$TALLY"; continue
  fi
  if [ "$speed" = "slow" ] && [ "$FULL" != "1" ] && [ -z "$ID" ]; then
    printf '%-10s %-52s %s\n' "$id" "$claim" "not run, needs FULL=1"
    echo skipped >> "$TALLY"; continue
  fi

  printf '%-10s %-52s ' "$id" "$claim"
  if eval "$cmd" > "$LOG" 2>&1; then
    printf 'holds\n'; echo passed >> "$TALLY"
  else
    printf 'FAILS\n'; echo failed >> "$TALLY"
    echo "      the check was: $cmd"
    sed 's/^/      /' "$LOG" | tail -8
  fi
done < "$LIST"

tally() { /usr/bin/grep -c "^$1\$" "$TALLY" 2>/dev/null | head -1 | tr -dc 0-9; }
passed=$(tally passed); failed=$(tally failed)
unchecked=$(tally unchecked); skipped=$(tally skipped)

echo
echo "holds: ${passed:-0}   FAILS: ${failed:-0}   unchecked: ${unchecked:-0}   not run: ${skipped:-0}"
[ "${failed:-0}" -eq 0 ] || echo "something that used to work does not" >&2
exit "${failed:-0}"
