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

# What the checks looked like when this began.
#
# bash reads a script as it runs it, by byte offset, so editing one mid-run
# makes it resume in the middle of a line it has never seen. A full run of this
# took an hour and reported two claims broken; both were that -- "line 105: ree:
# command not found" -- because a file was edited while the run was inside it.
#
# It is not prevented, because refusing to run while somebody is working is its
# own kind of breakage. It is noticed: if the checks changed under the run, the
# run says its own result is not to be trusted, which is the one thing worse
# than not running at all.
fingerprint() { find scripts .claude -type f -newermt "@0" -exec ls -l {} + 2>/dev/null | cksum; }
BEFORE="$(fingerprint)"

printf '%-10s %-52s %s\n' claim what result
echo

# The list is read on fd 3 and every check gets /dev/null for its stdin.
#
# On fd 0 the first check that reads stdin swallows the rest of the registry:
# a full run stopped after three rows and reported "holds: 2" as though that
# were the whole picture. A gate that truncates itself in silence is worse than
# no gate, because it reports a clean answer about work it never did.
while IFS=$'\t' read -r id tags speed claim cmd <&3; do
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
  if [ "$speed" != "fast" ] && [ "$FULL" != "1" ] && [ -z "$ID" ]; then
    printf '%-10s %-52s %s\n' "$id" "$claim" "not run, needs FULL=1"
    echo skipped >> "$TALLY"; continue
  fi

  # Bounded, because one check that hangs stalls every check after it.
  #
  # homes-are-separate.sh ran for forty-six minutes inside a full run and had to
  # be killed by hand; everything queued behind it simply never happened. A
  # check that takes longer than its bound has failed as far as this is
  # concerned -- an answer that never arrives is not a pass.
  printf '%-10s %-52s ' "$id" "$claim"
  # Three tiers, because two were not enough to tell a hang from a long job.
  #
  # homes-are-separate.sh launches every Lukotta installed in /Applications and
  # each launch boots a machine, so it genuinely runs past half an hour. It was
  # reported as failing on its bound twice, which reads as broken and is not.
  bound="${CHECK_TIMEOUT:-1800}"
  case "$speed" in
    fast) bound="${FAST_TIMEOUT:-300}" ;;
    long) bound="${LONG_TIMEOUT:-5400}" ;;
  esac
  if timeout "$bound" bash -c "$cmd" > "$LOG" 2>&1 < /dev/null; then
    printf 'holds\n'; echo passed >> "$TALLY"
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      printf 'FAILS (took longer than %ss)\n' "$bound"
    else
      printf 'FAILS\n'
    fi
    echo failed >> "$TALLY"
    echo "      the check was: $cmd"
    sed 's/^/      /' "$LOG" | tail -8
  fi
done 3< "$LIST"

tally() { /usr/bin/grep -c "^$1\$" "$TALLY" 2>/dev/null | head -1 | tr -dc 0-9; }
passed=$(tally passed); failed=$(tally failed)
unchecked=$(tally unchecked); skipped=$(tally skipped)

echo
if [ "$(fingerprint)" != "$BEFORE" ]; then
  echo "the checks were edited while this ran, so this result means nothing;"
  echo "run it again on a settled tree." >&2
  exit 2
fi
echo "holds: ${passed:-0}   FAILS: ${failed:-0}   unchecked: ${unchecked:-0}   not run: ${skipped:-0}"
[ "${failed:-0}" -eq 0 ] || echo "something that used to work does not" >&2
exit "${failed:-0}"
