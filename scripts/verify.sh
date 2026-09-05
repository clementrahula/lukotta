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

# One file per row, under the tree, so a failure can still be read after the
# run. Cleared at the start rather than at the end: the logs of the run you
# just did are the ones worth having.
LOGDIR=".verify-logs"
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
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

# The app the checks drive, chosen because it can be driven.
#
# Several rows pass "$LUKOTTA_ENGINE" and nothing ever set it, so it expanded to
# nothing and each harness fell back to its own default -- a path naming an app
# by name and hoping. On 2026-09-05 that default was a Dev build compiled
# without devtools, five Lukotta bundles were installed, and goal4 failed with
# "has no --drive" against an app nobody had asked it to use.
#
# So it is resolved once, here, by the only property that matters: the binary
# answers to --drive. Newest first, because that is the one just built.
#
# grep -c rather than -q: under pipefail a -q match exits at once, strings dies
# of SIGPIPE, and the test rejects every bundle that is fine.
if [ -z "${LUKOTTA_ENGINE:-}" ]; then
  for bundle in $(/bin/ls -td /Applications/*.app 2>/dev/null); do
    binary="$bundle/Contents/MacOS/$(basename "$bundle" .app)"
    engine="$bundle/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"
    [ -x "$binary" ] && [ -x "$engine" ] || continue
    [ "$(strings -a "$binary" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || continue
    LUKOTTA_ENGINE="$engine"; break
  done
  export LUKOTTA_ENGINE
fi
if [ -z "${LUKOTTA_ENGINE:-}" ]; then
  echo "no installed app answers to --drive; build one:" >&2
  echo "  LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh" >&2
  exit 2
fi
echo "driving ${LUKOTTA_ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"

# And whether that app was built from these sources.
#
# Every check that opens a drive runs whatever is installed in /Applications,
# and nothing here said whether that was built from the tree it is being taken
# as evidence about. On 2026-09-05 a full run spent twenty-five minutes
# measuring a build from before a revert: the numbers described code that no
# longer existed, and the run had no way to say so. It reads as a clean answer
# about the work in front of you, which is the same shape as every other
# instrument that has lied here.
#
# Noticed at the end rather than refused at the start, for the same reason as
# the fingerprint above: a run that took half an hour should say what it
# learned and then say what it was measuring, not throw both away.
STALE_BUILD=""
_bundle="${LUKOTTA_ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
_binary="$_bundle/Contents/MacOS/$(basename "$_bundle" .app)"
# The tests are excluded on purpose. They are not compiled into the app, so
# editing one cannot make the installed bundle describe different behaviour --
# and a guard that fires on them would cry stale after every test written
# during a run, which is how a true guard gets switched off.
if [ -x "$_binary" ] && [ -n "$(find sources resources -type f \
     -newer "$_binary" -not -path 'sources/LukottaTests/*' -print 2>/dev/null | head -1)" ]; then
  STALE_BUILD="$_bundle"
fi

echo

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
  # A clean slate between checks.
  #
  # heals-itself.sh failed one step of 185 inside a full run and passed on its
  # own minutes later. Nothing was wrong with it: the check before had left
  # shares mounted and images attached, and it inherited them. A check that
  # passes alone and fails in company is the harness contaminating itself, and
  # it reads as the app being flaky -- which is the most expensive kind of
  # wrong answer this gate can give.
  for __point in $(mount | /usr/bin/grep '\.local:' | awk '{print $3}' \
                   | awk '{print length, $0}' | sort -rn | cut -d" " -f2-); do
    umount "$__point" >/dev/null 2>&1 || umount -f "$__point" >/dev/null 2>&1
  done
  for __dev in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' \
                 | awk '{print $1}'); do
    hdiutil detach "$__dev" -force -quiet >/dev/null 2>&1
  done

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
  LOG="$LOGDIR/$id.log"
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
    echo "      all of it: $LOGDIR/$id.log"
  fi
done 3< "$LIST"

tally() { /usr/bin/grep -c "^$1\$" "$TALLY" 2>/dev/null | head -1 | tr -dc 0-9; }
passed=$(tally passed); failed=$(tally failed)
unchecked=$(tally unchecked); skipped=$(tally skipped)

echo
if [ -n "${STALE_BUILD:-}" ]; then
  echo "$STALE_BUILD is older than the sources, so this measured code that is"
  echo "no longer in the tree; rebuild and run it again." >&2
  echo "  LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh" >&2
  # And installed. build-app.sh writes into dist/ and stops there; every check
  # here drives what is in /Applications. Saying only the first half is how a
  # run came back green about a build that was never replaced.
  echo "  ditto \"dist/$(basename "$STALE_BUILD")\" \"$STALE_BUILD\"" >&2
  exit 2
fi
if [ "$(fingerprint)" != "$BEFORE" ]; then
  echo "the checks were edited while this ran, so this result means nothing;"
  echo "run it again on a settled tree." >&2
  exit 2
fi
echo "holds: ${passed:-0}   FAILS: ${failed:-0}   unchecked: ${unchecked:-0}   not run: ${skipped:-0}"
[ "${failed:-0}" -eq 0 ] || echo "something that used to work does not" >&2
exit "${failed:-0}"
