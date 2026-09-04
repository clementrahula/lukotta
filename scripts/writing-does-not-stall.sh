#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Item 1, as a pass or a fail: no request goes unanswered long enough to be seen.
#
# WHAT IT JUDGES, AND WHY IT IS NO LONGER FIVE SECONDS
#
# It used to fail a run where any request went unanswered for five seconds,
# resting on one sentence: macOS tells somebody the server has stopped
# responding at five seconds. That was true of a default NFS mount and it is not
# true of this one, because of the options this project added to stop exactly
# that dialog -- dumbtimer, timeo=600, retrans=5, mutejukebox, deadtimeout=900.
#
# Measured on 2026-09-05, over six hours that include a run whose worst request
# took eighteen seconds:
#
#     genuine "not responding" events logged by macOS     0
#     NFS log lines in the same window                   12,645
#
# So the five-second bar had stopped standing for the thing it was named after,
# and a harness that fails on a proxy nobody sees is measuring its own history.
#
# What reaches a person is judged instead, and both halves are asserted:
#
#   - no operation fails. A soft mount that exhausts its retries returns
#     ETIMEDOUT to whoever asked, and that is a copy erroring in front of
#     somebody. It happened once, in a run where the reclaim walk was reading a
#     byte of every file beside the copy.
#   - macOS logs no "server not responding". Asked of `log show` over the run's
#     own window, because `log stream` does not carry these kernel messages --
#     the first attempt at this measurement returned an empty file from a
#     command that had failed to parse, which reads exactly like an absence of
#     events.
#
# The latency distribution is still printed, in full, because it is the number
# that steers the work even when it is not the number that fails the run.
#
# flush-latency.sh measures the distribution and deliberately renders no verdict
# -- its own note says so, and it is right to: a worst case of four seconds is
# one bad moment away from the dialog and reads as success. But a claim with no
# pass and no fail cannot be checked, and an unchecked claim quietly becomes a
# remembered one. So the measuring stays verdict-free and the judgement lives
# here, where the threshold can be stated once and argued with.
#
# It opens the drive the way a person does, through the app, because the
# durability options and the NFS parameters that decide this are chosen by the
# app and not by a hand-written mount.
#
#   ./scripts/writing-does-not-stall.sh
#   MB=800 ./scripts/writing-does-not-stall.sh
#   IMAGE=/dev/disk4s1 ./scripts/writing-does-not-stall.sh   # a real drive
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="${OUT:-$HOME/.lukotta-testvols}"
IMAGE="${IMAGE:-ntfs-vectors.img}"
# Sized against the measurement this claim came from.
#
# The stall was found over a thirteen-gigabyte copy: p50 28ms, p90 31ms, p99
# 4.66s, worst 8.95s, nine requests past five seconds. At 400 MB this reported
# a worst case of 31ms, which is not evidence the stall is gone -- it is
# evidence that 400 MB does not reach the window where it lived. The slow
# moments cluster in the thirty to fifty seconds after a file closes, and a
# write that finishes in one second barely opens that window.
#
# 1600 MB is what the fixture holds and is the most this can ask for without a
# larger one. It is still well short of thirteen gigabytes, and that gap is
# written down beside the result rather than left for somebody to assume away.
MB="${MB:-1600}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
IMG="$OUT/$IMAGE"

# A real drive, or a fixture.
#
# IMAGE may name a device -- IMAGE=/dev/disk4s1 -- and then nothing is attached
# and nothing is detached; the drive is opened where it already is. This exists
# because the claim cannot be proven any other way: the stall was found on a USB
# drive, and a fixture on the internal SSD has never reproduced it. Measured,
# and written down beside the result: 1600 MB through the fixture answers in
# 31 ms at worst, against a p99 of 4.66 s on the drive the fault lived on. That
# is not the fault being gone, it is the fixture never reaching it.
DEVICE_MODE=0
case "$IMAGE" in
  /dev/disk*) DEVICE_MODE=1; IMG="$IMAGE" ;;
esac

[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
if [ "$DEVICE_MODE" = 1 ]; then
  [ -b "$IMG" ] || [ -c "$IMG" ] || { echo "error: no device $IMG" >&2; exit 2; }
else
  [ -f "$IMG" ] || { echo "error: no $IMG" >&2; exit 2; }
fi
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

WORK="$(mktemp -d)"
DEV=""
release_drives() {
  for p in $(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  # Only images are detached, and only when this run attached one. Detaching
  # everything would pull out a drive somebody plugged in, and in device mode
  # the thing under test is exactly such a drive.
  if [ "$DEVICE_MODE" = 0 ]; then
    for d in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}'); do
      hdiutil detach "$d" -force -quiet >/dev/null 2>&1
    done
  fi
  DEV=""
}
trap 'release_drives; rm -rf "$WORK"' EXIT
release_drives

if [ "$DEVICE_MODE" = 1 ]; then
  DEV="$IMG"
else
  DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${DEV:-}" ] || { echo "error: $IMAGE would not attach" >&2; exit 2; }
fi
timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "error: did not open: $(tail -1 "$WORK/open.log")" >&2; exit 2; }
# The mount this opened, found by the device it was given -- the engine names
# the share after it, so "diskN.local:" is what appears in the table.
#
# Taking the first ":/mnt/" line instead measured whatever else happened to be
# mounted: a leftover exFAT volume from an interrupted run was picked up and
# reported as this drive failing, complete with stale handles that had nothing
# to do with the image under test.
SHARE="$(basename "$DEV").local:"
POINT="$(mount | /usr/bin/grep -F "$SHARE" | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "error: opened and nothing is served" >&2; exit 2; }
echo "opened $POINT through the app"

# Optionally with the memory squeezed, which is the only way this fixture can
# be made to behave like the drive the stall was found on.
#
# 1600 MB went in three seconds here -- 533 MB/s, because the image sits on the
# internal SSD -- and the stall lived in writeback to a slow drive. Nothing on
# this Mac can make an SSD slow. What it can do is take the memory away, so the
# writeback has to compete for it instead of being absorbed, which is the same
# pressure arriving by a different road. It is not the same test and it is not
# claimed to be; it is the closest this hardware comes.
#
# The ballast is the one from eight-gig-pressure.sh, verbatim: from urandom
# rather than zeroes, because the compressor hands back a zero page for free
# and ballast that compresses is not ballast, and re-touched on every round so
# these stay the pages least worth compressing.
BALLAST=""
if [ "${PRESSURE:-0}" = "1" ]; then
  total_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  hold=$(( total_gb - 8 ))
  if [ "$hold" -gt 0 ]; then
    /usr/bin/python3 - "$hold" <<'BALLAST_PY' &
import os, sys, time
gb = int(sys.argv[1])
chunks = []
for _ in range(gb * 8):
    chunks.append(bytearray(os.urandom(128 * 1024 * 1024)))
while True:
    for c in chunks:
        c[0] = (c[0] + 1) & 0xFF
        c[-1] = (c[-1] + 1) & 0xFF
    time.sleep(5)
BALLAST_PY
    BALLAST=$!
    echo "holding ${hold} GB so ~8 GB is left (pid $BALLAST)"
    for _ in $(seq 1 120); do
      free_mb=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print int($3*16384/1048576)}')
      [ "${free_mb:-0}" -le 400 ] && break
      kill -0 "$BALLAST" 2>/dev/null || { echo "  the ballast died" >&2; break; }
      sleep 2
    done
    echo "  ${free_mb:-unknown} MB free while this runs"
  fi
fi
release_ballast() { [ -n "${BALLAST:-}" ] && kill "$BALLAST" 2>/dev/null; BALLAST=""; }
trap 'release_ballast; release_drives; rm -rf "$WORK"' EXIT

# Noted before the writing starts, so the log is asked about this run and not
# about the week.
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
bash scripts/flush-latency.sh "$POINT" "$MB" 1 2>&1 | tee "$WORK/latency.log"
release_ballast

over=$(/usr/bin/grep -o 'over 5s (the threshold): [0-9]*' "$WORK/latency.log" \
  | awk '{print $NF}' | head -1)
worst=$(/usr/bin/grep -o 'worst [0-9.]*s' "$WORK/latency.log" | awk '{print $2}' | head -1)

# Did anything actually fail, and did macOS say anything.
#
# `log show` rather than `log stream`: streaming does not carry these kernel
# messages, and an empty stream reads exactly like a quiet one.
said=$(/usr/bin/log show --start "$STARTED_AT" --style compact \
  --predicate 'eventMessage CONTAINS[c] "not responding"' 2>/dev/null \
  | /usr/bin/grep -c "server not responding" || true)
errored=$(/usr/bin/grep -ciE "timed out|input/output error|stale" "$WORK/latency.log" || true)

echo
if [ -z "${over:-}" ]; then
  echo "RESULT: the measurement produced no reading to judge" >&2
  exit 1
fi
echo "  worst request ${worst:-unknown}, ${over:-?} past five seconds"
echo "  operations that failed: $errored"
echo "  times macOS called the server unresponsive: $said"
if [ "${errored:-0}" -eq 0 ] && [ "${said:-0}" -eq 0 ]; then
  echo "RESULT: the copy finished with nothing failing and nothing said"
  exit 0
fi
echo "RESULT: $errored operation(s) failed and macOS said it $said time(s)" >&2
echo "        that is what a person sees mid-copy" >&2
exit 1
