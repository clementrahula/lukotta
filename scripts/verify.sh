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
# Job control, so a backgrounded check becomes its own process group leader and
# can be signalled as a group. Without it `&` starts no new group in a
# non-interactive shell, and stopping this script leaves the row -- and the
# harnesses and engines beneath it -- running. Those harnesses kill engine
# processes by pattern, so an orphan goes on killing the engines of whatever
# runs next; that cost a goal1 measurement on 2026-09-05 before it was noticed.
set -m

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
# Stopped by hand, and the tree goes too.
#
# Without this, killing verify.sh left the running row -- and its harnesses, and
# their engines -- alive. See the note on the row launch below for what that
# orphan then did to the next run's numbers.
cleanup_run() {
  rm -f "$LOG" "$TALLY"
  # The row that is running, and everything under it.
  #
  # Only that one process group is signalled. `kill -- -$$` was written here
  # first and is a different thing entirely: this script is not a group leader
  # when it is started from a shell, so that would have signalled the shell's
  # group -- the terminal, and whatever else was running in it.
  if [ -n "${ROW_PID:-}" ] && kill -0 "$ROW_PID" 2>/dev/null; then
    kill -TERM -- "-$ROW_PID" 2>/dev/null || kill -TERM "$ROW_PID" 2>/dev/null
    sleep 2
    kill -KILL -- "-$ROW_PID" 2>/dev/null || kill -KILL "$ROW_PID" 2>/dev/null
  fi
}
# A signal cleans up and stops. A trap handler runs and then bash carries on
# with what it was doing, so `trap cleanup_run TERM` reaped the running row and
# then started the next one -- a gate that has been asked to stop and answers by
# continuing. Measured: TERM took the row and its engines and left verify.sh
# running.
stop_run() { cleanup_run; trap - EXIT; exit 130; }
trap cleanup_run EXIT
trap stop_run INT TERM

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
# The glob itself, never `for x in $(ls)`. Every bundle worth finding here is
# called "Lukotta Beta.app" or "Drive Unlocker.app", and word splitting cut both
# in half: the first attempt at this looked for "/Applications/Lukotta" and
# "Beta.app" and concluded that no installed app answers to --drive, on a Mac
# with two that do.
if [ -z "${LUKOTTA_ENGINE:-}" ]; then
  newest=""; newest_engine=""
  for bundle in /Applications/*.app; do
    binary="$bundle/Contents/MacOS/$(basename "$bundle" .app)"
    engine="$bundle/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"
    [ -x "$binary" ] && [ -x "$engine" ] || continue
    [ "$(strings -a "$binary" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || continue
    if [ -z "$newest" ] || [ "$binary" -nt "$newest" ]; then
      newest="$binary"; newest_engine="$engine"
    fi
  done
  LUKOTTA_ENGINE="$newest_engine"
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
# the fingerprint above: a run that took half an hour should say what it learned
# and then say what it was measuring, not throw both away.
#
# Asked at the end too, which is not the same thing and is why this is a
# function. It was first written as a variable set here, and that answered a
# different question -- whether the build was stale when the run began. A run on
# 2026-09-05 measured a build from 05:03 against sources committed at 05:13 and
# 06:01, edited while it ran, which is the ordinary way of working here, and
# this said nothing: at the moment it looked, the build was current. What matters
# is whether the numbers describe the tree they will be read against, and only
# the end of the run knows that.
#
# The tests are excluded on purpose. They are not compiled into the app, so
# editing one cannot make the installed bundle describe different behaviour --
# and a guard that fires on them would cry stale after every test written during
# a run, which is how a true guard gets switched off.
stale_build() {
  _bundle="${LUKOTTA_ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
  _binary="$_bundle/Contents/MacOS/$(basename "$_bundle" .app)"
  [ -x "$_binary" ] || return 1
  [ -n "$(find sources resources -type f -newer "$_binary" \
        -not -path 'sources/LukottaTests/*' -print 2>/dev/null | head -1)" ] || return 1
  printf '%s\n' "$_bundle"
}

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
  # A row that wants a drive nobody has plugged in has not failed.
  #
  # `durable` writes to a spare device and kills the machine, so it cannot run
  # on an image -- the host's buffer cache survives the kill and the vector
  # under-reports. Without LUKOTTA_TEST_DEVICE it stopped at its first line and
  # was counted as FAILS, which reads as "a committed write no longer survives"
  # on a run where nothing of the kind was measured. A missing instrument is not
  # a bad measurement.
  #
  # Still not a pass: it lands in the same tally as everything else that did not
  # run, and the summary shows that number beside the ones that did.
  case ",$tags," in
    *,hardware,*)
      if [ -z "${LUKOTTA_TEST_DEVICE:-}" ] || [ ! -e "${LUKOTTA_TEST_DEVICE:-}" ]; then
        printf '%-10s %-52s %s\n' "$id" "$claim" "not run, needs a spare drive"
        echo skipped >> "$TALLY"; continue
      fi
      ;;
  esac

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
  # The check dies with this run, and so does everything it started.
  #
  # `timeout` signals one process. A row is a shell that starts harnesses that
  # start engines, so killing this script left the whole tree running -- and
  # these harnesses kill engine processes by pattern, which means an orphan from
  # a run somebody stopped goes on killing the engines of whatever runs next.
  #
  # Measured on 2026-09-05, and it had already cost a measurement before it was
  # noticed: a goal5 sweep orphaned by a stopped gate was still running fifteen
  # minutes later, holding the engine lock and killing engines, while the next
  # thing along wrote into a mount whose server had gone -- "dd: error writing:
  # Device not configured", reported by that row as a clean copy.
  #
  # Plain `timeout` already runs the command in its own process group and
  # signals the whole group, which is what is wanted here. `--foreground` turns
  # that off -- it exists for interactive use -- and was written here first by
  # somebody reading the name rather than the manual. -k adds a KILL for a
  # harness that ignores the TERM.
  ROW_PID=""
  timeout -k 10 "$bound" bash -c "$cmd" > "$LOG" 2>&1 < /dev/null &
  ROW_PID=$!
  if wait "$ROW_PID"; then
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
STALE_BUILD="$(stale_build)"
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
