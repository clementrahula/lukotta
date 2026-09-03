#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A dozen volumes open at once, opened the way a person opens them.
#
# WHY THIS EXISTS SEPARATELY FROM THE MEASUREMENT ALREADY WRITTEN DOWN
#
# Twelve volumes were measured on 2026-09-03 and the numbers are in
# MEASUREMENTS.md: 1.87 GB in total, byte-identical on all twelve, a shell
# still answering in 28 ms. Every one of those was opened by calling the engine
# directly, and the engine takes a loopback address as it finds one.
#
# The app does not. It asks its daemon for twelve addresses first and will not
# open a drive it has no address for -- and until 1.22.7-beta.2 the daemon
# counted ::1 and fe80::1 among them, answered twelve when ten existed, and
# added nothing. So the app could never have opened more than ten, and the
# measurement that said a dozen worked had not been anywhere near the code that
# would have shown it.
#
# This opens them through the app, one `--drive open=` at a time, exactly as
# the window does. If the ceiling is still there it appears here and nowhere
# else.
#
#   ./scripts/crowd-through-the-app.sh
#   COUNT=12 ./scripts/crowd-through-the-app.sh
#   PRESSURE=1 ./scripts/crowd-through-the-app.sh   # and as an 8 GB Mac feels it
#
# LUKOTTA_ENGINE names the bundle to test, and it must be one whose daemon is
# installed -- see the note in dirty-ntfs-repair.sh about a channel with none.
set -uo pipefail

OUT="${1:-$HOME/.lukotta-testvols}"
COUNT="${COUNT:-12}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"

# And whether this bundle can be driven at all.
#
# The headless switches live inside `#if DEVTOOLS`, and a beta or release build
# does not carry them. Handed --drive anyway the app does not complain: it
# launches, hides its window and sits in its run loop until something kills it,
# which reads exactly like a mount that hangs and was read as one for most of a
# morning. One second of strings answers it.
can_be_driven() {
  # grep -c rather than -q, and a count rather than an exit status. Under
  # `set -o pipefail`, `grep -q` matches, exits at once, `strings` dies of
  # SIGPIPE, and the pipeline reports 141 -- so the check refused every bundle
  # that was fine, including the one it had just been proved against.
  [ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ]
}

can_be_driven || {
  echo "error: $APP_BUNDLE has no --drive; it was not built with devtools" >&2
  echo "       build one with LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh" >&2
  exit 2
}
[ -f "/Library/LaunchDaemons/$APP_ID.helper.plist" ] || {
  echo "error: no daemon for $APP_ID; this channel cannot mount on this Mac" >&2
  exit 2
}
[ -d "$OUT/crowd" ] || {
  echo "error: no volumes in $OUT/crowd; run make-test-volumes.sh --crowd" >&2
  exit 2
}

WORK="$(mktemp -d)"
DEVS=()
fail=0

clean_up() {
  # What this run wrote is taken off again before the volumes go.
  #
  # It never was, and the fixtures are 64 MB, so every run left another sixty
  # files behind: after a few runs one volume showed 16 MB free where its
  # neighbour showed 37, which reads exactly like a volume that did not receive
  # its copy. It was leftovers, and the next few runs after that would have
  # failed for want of space with nothing wrong with the app.
  for point in $(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | sort -u); do
    rm -rf "$point/crowd-write" "$point/fill" >/dev/null 2>&1
  done
  for point in $(mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | sort -u); do
    umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1
  done
  for dev in "${DEVS[@]:-}"; do
    [ -n "$dev" ] && hdiutil detach "$dev" -quiet >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap clean_up EXIT

echo "opening $COUNT volumes through $APP_ID, one at a time"
echo "  lo0 carries $(ifconfig lo0 | /usr/bin/grep -c 'inet ') addresses that can serve"

opened=0
for i in $(seq 1 "$COUNT"); do
  img="$OUT/crowd/drive$i.img"
  [ -f "$img" ] || { echo "  no $img" >&2; fail=1; continue; }
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$img" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${dev:-}" ] || { echo "  drive$i would not attach" >&2; fail=1; continue; }
  DEVS+=("$dev")
  # Each open returns once the volume is served, so these are sequential and
  # the count below is the count that survived, not the count attempted.
  began="$(date +%s)"
  if timeout 300 "$APP" --drive open="$dev" > "$WORK/open$i.log" 2>&1; then
    opened=$((opened + 1))
    took=$(( $(date +%s) - began ))
    echo "$took" >> "$WORK/opens"
    printf '  %2d of %s open, %s s\n' "$opened" "$COUNT" "$took"
  else
    echo "  drive$i did not open: $(tail -1 "$WORK/open$i.log")" >&2
    fail=1
  fi
done

# How long each one took, which is what somebody waiting actually feels. The
# last is the one that matters: if opening the twelfth costs more than opening
# the first, the app is paying for the ones already open.
if [ -s "$WORK/opens" ]; then
  printf 'seconds to open: first %s, last %s, slowest %s\n' \
    "$(head -1 "$WORK/opens")" "$(tail -1 "$WORK/opens")" \
    "$(sort -n "$WORK/opens" | tail -1)"
fi

served="$(mount | /usr/bin/grep -c 'CROWD')"
echo "mounts being served: $served"
echo "  lo0 now carries $(ifconfig lo0 | /usr/bin/grep -c 'inet ') addresses that can serve"

# Written to all of them at once, then read back. Sums taken from the source,
# not from the volume, so a file that never arrived is a difference and not a
# matching pair of absences.
mount | /usr/bin/grep 'CROWD' | awk '{print $3}' > "$WORK/points"
# Optionally filled first, to a known margin on every volume.
#
# All three stale handles so far landed on volumes an earlier run had left
# nearly full, and the runs that followed -- on volumes the harness had since
# cleaned -- were all clean. A full volume on its own is not it: filled to
# 2.8 MB free and copied 6 MB into, one volume answered "No space left on
# device" sixty times over, which is exactly right. So what is left to try is
# both at once, which is what this does.
if [ -n "${FILL_MARGIN_MB:-}" ]; then
  echo "filling every volume to ${FILL_MARGIN_MB} MB free before writing"
  while read -r point; do
    mkdir -p "$point/fill"
    n=0
    while :; do
      free_mb=$(df -m "$point" | tail -1 | awk '{print $4}')
      [ "${free_mb:-0}" -le "$FILL_MARGIN_MB" ] && break
      n=$((n + 1))
      head -c 1048576 /dev/urandom > "$point/fill/pad$n" 2>/dev/null || break
      [ "$n" -gt 200 ] && break
    done
  done < "$WORK/points"
  echo "  free on each: $(while read -r p; do df -m "$p" | tail -1 \
    | awk '{printf "%s ", $4}'; done < "$WORK/points")MB"
fi

SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 60); do head -c 100000 /dev/urandom > "$SRC/f$i.bin"; done
(cd "$SRC" && find . -type f -exec shasum -a 256 {} \; | sort) > "$WORK/before.sums"

# Each copy's complaint is kept, not discarded.
#
# It used to be `>/dev/null 2>&1`, and on 2026-09-03 one volume of twelve came
# back with nothing on it while the run reported "wrote to 12 volumes in 2 s".
# Whatever ditto said about that volume had been thrown away, so the one line
# that would have named the fault did not exist.
started="$(date +%s)"
while read -r point; do
  ditto "$SRC" "$point/crowd-write" \
    > "$WORK/ditto$(basename "$point").log" 2>&1 \
    || echo "$point" >> "$WORK/write-failed" &
done < "$WORK/points"
wait
echo "wrote to $(wc -l < "$WORK/points" | tr -d ' ') volumes in $(( $(date +%s) - started )) s"
if [ -s "$WORK/write-failed" ]; then
  while read -r point; do
    echo "  copy onto $point failed: $(tail -2 "$WORK/ditto$(basename "$point").log" \
      | tr '\n' ' ')" >&2
  done < "$WORK/write-failed"
  fail=1
fi

# Read back, with a directory that cannot be read told apart from one whose
# contents are wrong.
#
# Both used to arrive as "$point differs": find's errors went to /dev/null, so
# a listing that failed produced an empty sums file, which differs from the
# expected sums exactly as a volume of corrupt files would. The first of those
# is the volume erroring under load; the second is data loss. They need
# different fixes and the instrument could not say which had happened.
identical=0; differing=0
while read -r point; do
  (cd "$point/crowd-write" && find . -type f -exec shasum -a 256 {} \; | sort) \
    > "$WORK/after.sums" 2>"$WORK/after.err"
  if diff -q "$WORK/before.sums" "$WORK/after.sums" >/dev/null 2>&1; then
    identical=$((identical + 1))
  else
    differing=$((differing + 1))
    want=$(wc -l < "$WORK/before.sums" | tr -d ' ')
    got=$(wc -l < "$WORK/after.sums" | tr -d ' ')
    if [ ! -d "$point/crowd-write" ]; then
      # The copy never made the directory, which is what a volume with no room
      # left does. Said plainly, because it used to arrive here as a "could not
      # be read" with the shell's own cd failure parsed as a filename -- and a
      # volume that was simply full then read as the stale-handle fault this
      # branch exists to catch.
      echo "  $point has no crowd-write; the copy made nothing" >&2
    elif [ -s "$WORK/after.err" ]; then
      echo "  $point could not be read: $(head -1 "$WORK/after.err")" >&2
      # Asked again straight away, and asked by name.
      #
      # A stale handle that heals on the next attempt is one handle going bad
      # under contention; one that keeps failing is a volume that has gone.
      # And a name resolves by LOOKUP rather than through the dead handle, so
      # if the file stats while the walk cannot reach it, everything is on the
      # volume and only the handle was wrong. Both are one second of work and
      # neither can be recovered afterwards.
      # Only a find(1) complaint carries a filename; anything else does not,
      # and taking one out of it invents a path nobody asked about.
      bad=""
      case "$(head -1 "$WORK/after.err")" in
        find:*) bad="$(head -1 "$WORK/after.err" | sed "s/^find: //; s/:.*//" | tr -d "'")" ;;
      esac
      (cd "$point/crowd-write" && find . -type f -exec shasum -a 256 {} \; | sort) \
        > "$WORK/again.sums" 2>"$WORK/again.err"
      if [ -s "$WORK/again.err" ]; then
        echo "    asked again: still failing, $(head -1 "$WORK/again.err")" >&2
      elif diff -q "$WORK/before.sums" "$WORK/again.sums" >/dev/null 2>&1; then
        echo "    asked again: every file read back correctly" >&2
      else
        echo "    asked again: readable, $(/usr/bin/grep -c . < "$WORK/again.sums") files" >&2
      fi
      [ -n "$bad" ] && \
        echo "    by name: $(ls -l "$point/crowd-write/$bad" 2>&1 | tail -1 | cut -c1-90)" >&2
      echo "    room: $(df -h "$point" 2>&1 | tail -1 | awk '{print $4 " free of " $2}')" >&2
      # Watched, because the first occurrence healed and the second did not
      # heal within a second, and nobody wrote down which it was at the time.
      #
      # A handle that comes back inside a couple of minutes with the right
      # bytes behind it is a wrong error message, which is bad. One that never
      # comes back, or comes back short, is data that did not arrive, which is
      # worse and needs a different fix. This is the only moment either can be
      # told from the other.
      healed=""
      for t in $(seq 1 60); do
        if (cd "$point/crowd-write" && find . -type f -exec shasum -a 256 {} \; \
             | sort) > "$WORK/heal.sums" 2>/dev/null; then
          [ -s "$WORK/heal.sums" ] && { healed="$((t * 3))"; break; }
        fi
        sleep 3
      done
      if [ -n "$healed" ]; then
        if diff -q "$WORK/before.sums" "$WORK/heal.sums" >/dev/null 2>&1; then
          echo "    healed after ${healed}s, every file correct" >&2
        else
          echo "    healed after ${healed}s, $(/usr/bin/grep -c . < "$WORK/heal.sums") of $(/usr/bin/grep -c . < "$WORK/before.sums") files" >&2
        fi
      else
        echo "    never healed in 180 s" >&2
      fi
    elif [ "$got" -lt "$want" ]; then
      echo "  $point listed $got of $want files, the rest are not there yet" >&2
      # Whether they arrive at all, and how late. A volume that fills in a
      # second was written correctly and read too early; one that never fills
      # in lost data. Those are not the same failure.
      for _ in $(seq 1 60); do
        late=$(ls -1 "$point/crowd-write" 2>/dev/null | wc -l | tr -d ' ')
        [ "$late" -ge "$want" ] && break
        sleep 1
      done
      echo "  $point settled at $late of $want files" >&2
    else
      echo "  $point has all $want files and $(comm -13 "$WORK/before.sums" \
        "$WORK/after.sums" | wc -l | tr -d ' ') of them are not the bytes written" >&2
    fi
  fi
done < "$WORK/points"
echo "byte-identical on $identical, wrong on $differing"
[ "$differing" -eq 0 ] || fail=1

# What it costs, and whether the Mac is still usable while it does.
# One pass of ps for both numbers.
#
# They were taken by two different expressions and printed side by side, which
# produced "0 processes, 2091 MB resident" -- a line that cannot be true, and
# that says plainly that one of the two was not working. Counted from the same
# rows that are summed, so they agree or neither is printed.
engine_ps="$(ps -Ao rss=,command= | /usr/bin/grep -E 'anylinuxfs|krun|vmproxy' \
  | /usr/bin/grep -v grep)"
procs="$(printf '%s\n' "$engine_ps" | /usr/bin/grep -c .)"
rss="$(printf '%s\n' "$engine_ps" | awk '{sum += $1} END {print int(sum / 1024)}')"
echo "engines: $procs processes, ${rss:-0} MB resident in total"

# Something the size of what a person does, timed with a clock that can see it.
#
# `time -p` reports hundredths of a second and echoing a word takes far less
# than one, so the old line read "0 ms" whatever the machine was doing: a
# measurement with no resolution at the size of the thing being measured. A
# listing of the home directory is what eight-gig-pressure.sh reports, so the
# two are comparable, and ten of them average out the noise.
shell_ms="$(/usr/bin/python3 - "$HOME" <<'MEASURE'
import subprocess, sys, time
began = time.perf_counter()
for _ in range(10):
    subprocess.run(["/bin/ls", "-l", sys.argv[1]],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(int((time.perf_counter() - began) / 10 * 1000))
MEASURE
)"
echo "shell responsiveness: ${shell_ms} ms to list the home directory"

# And the same dozen measured as an 8 GB Mac would feel them, if asked.
#
# Item 8 names a machine this one is not, and eight-gig-pressure.sh answers
# that by holding ballast until what is left free is what an 8 GB Mac has. It
# has only ever run against volumes opened by calling the engine, which is not
# the route a person takes -- so the two belong in one action rather than two,
# with the volumes still open and nothing else in flight.
if [ "${PRESSURE:-0}" = "1" ] && [ "$opened" -eq "$COUNT" ]; then
  echo
  echo "holding ballast, and measuring the same $COUNT inside it"
  bash "$(dirname "$0")/eight-gig-pressure.sh" || fail=1
fi

# Kept open, so a second harness can use the same twelve.
#
# The visibility fault this harness found happens once in three runs and takes
# four minutes to reach, all of it spent opening volumes. copy-visibility.sh
# does the copy part alone against volumes already open, so with HOLD=1 the
# four minutes are paid once and the fault can be hunted in cycles of seconds.
if [ "${HOLD:-0}" = "1" ]; then
  echo
  echo "holding $opened volumes open; touch /tmp/.crowd-release to let them go"
  rm -f /tmp/.crowd-release
  for _ in $(seq 1 3600); do
    [ -f /tmp/.crowd-release ] && break
    sleep 1
  done
  rm -f /tmp/.crowd-release
fi

echo
if [ "$opened" -lt "$COUNT" ]; then
  echo "RESULT: $opened of $COUNT opened through the app" >&2
  fail=1
else
  echo "RESULT: all $COUNT opened through the app, $identical byte-identical"
fi
exit "$fail"
