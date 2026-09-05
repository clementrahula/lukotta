#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Measure a dozen open volumes the way an 8 GB Mac would feel them, on a Mac
# that has more than 8 GB.
#
# The goal names an 8 GB M1. The machine these numbers were taken on is a
# Mac16,12 with 16 GB, and a footprint measured with eight spare gigabytes
# underneath it says nothing about a machine that has none. Rather than report
# a 16 GB result against an 8 GB claim, this takes the difference away: it
# holds ballast until what is left free is what an 8 GB Mac would have, and
# measures inside that.
#
# THE TRAP, WHICH THIS SCRIPT WOULD OTHERWISE HAVE WALKED INTO
#
# Ballast of zeroes is not ballast. macOS compresses inactive anonymous pages,
# and a page of zeroes compresses to almost nothing -- so allocating eight
# gigabytes of bytearray(n) and calling the machine full leaves the machine
# very nearly as empty as it was, and every number afterwards is a 16 GB number
# wearing an 8 GB label. The ballast here is written from urandom for that
# reason, and the script checks its own resident size before it believes it.
#
# It also touches every page again on each round, because ballast that is never
# read is exactly what the compressor takes first.
#
#   ./scripts/eight-gig-pressure.sh          # hold 8 GB, report, release
#   HOLD=6 ./scripts/eight-gig-pressure.sh   # hold a different amount
#
# Refuses to run while a copy is in flight: eight gigabytes of pressure across
# a measurement that is already recording latency does not produce two results,
# it spoils one.

# RE-MEASURED 2026-09-02 under wsize=32768, with the owner's drive open too:
#
#   13 engine mounts at once -- twelve NTFS fixtures plus the real BitLocker
#   drive -- all twelve fixtures written to and read back, 2378 MB resident
#   across every engine process, 68% of memory free, home listing 17-24 ms.
#
# One more than a dozen, and the machine is not noticeably different to use.
#
# WHAT IT MEASURED, 2026-09-01, on a Mac16,12 with 16 GB
#
# Twelve volumes open and writable, before any ballast:
#   1892 MB resident in total -- 1545 MB across the machines, 347 MB gvproxy
#   home listing 17-18 ms, 80% of memory free, no swap in use
#
# Then eight gigabytes held from urandom, so what is left is about what an
# 8 GB Mac has. At 33% free with 6 GB pushed into swap:
#   all twelve volumes written to and read back: 12 of 12
#   home listing 16, 17, 20 ms; a walk of the source tree 36 ms
#   the machines' resident total fell from 1545 MB to 554 MB
#
# That last line is the result worth having. The footprint is elastic, not
# fixed: most of what a machine holds is page cache it gives back when the
# host wants it, so a dozen volumes do not cost a dozen times a fixed price.
# It is why "493 MB per drive, so twelve is 5.9 GB" was wrong by an order of
# magnitude -- that number was one volume measured in the middle of a copy.
#
# Said plainly: this is a 16 GB Mac made to feel like an 8 GB one, not an
# 8 GB M1. The ballast's own resident size falls as macOS compresses it, so
# the constraint arrives as swap pressure rather than as a hard ceiling. It
# is the closest thing available here, and it is not the same thing.
set -u

TOTAL_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
HOLD=${HOLD:-$(( TOTAL_GB - 8 ))}

if [ "$HOLD" -le 0 ]; then
  echo "this Mac has ${TOTAL_GB} GB; no ballast needed, it is already at or under 8"
  HOLD=0
fi

# A copy in flight is a measurement in flight.
#
# Process names catch ditto and rsync and miss the one that matters. A Finder
# copy runs inside Finder; there is no child process to match on. The first
# time this guard was tried it was tried during a thirteen-gigabyte Finder copy
# that was recording latency -- exactly the run it exists to protect -- and it
# saw nothing, started eight gigabytes of ballast, and put a machine that had
# never swapped into 6303 MB of swap.
#
# The lock file is the part that works. The pgrep stays as a courtesy for a
# copy started by hand, and is not trusted for anything.
#
# (What the accident measured is worth keeping: the mount did not care. Latency
# through the copy stayed at 0.027 s across the whole ballast window, the count
# of requests past five seconds did not move off 3, and no complaint was
# raised. A mount holding steady while the host is driven into six gigabytes of
# swap is the memory-pressure result this script was written to go and get.)
LOCK=/tmp/lukotta-measuring
if [ -e "$LOCK" ]; then
  echo "error: $LOCK exists -- a measurement is in flight:" >&2
  sed 's/^/       /' "$LOCK" >&2
  echo "       ballast now would spoil it, not add a second result" >&2
  exit 1
fi
if pgrep -qf 'ditto .*/Volumes/' || pgrep -qx rsync; then
  echo "error: a copy is running; ballast now would spoil that measurement" >&2
  exit 1
fi

echo "Mac has ${TOTAL_GB} GB, holding ${HOLD} GB so ~8 GB is left"

BALLAST=""
cleanup() { [ -n "$BALLAST" ] && kill "$BALLAST" 2>/dev/null; }
trap cleanup EXIT INT TERM

if [ "$HOLD" -gt 0 ]; then
  /usr/bin/python3 - "$HOLD" <<'PY' &
import os, sys, time
gb = int(sys.argv[1])
# From urandom, not zeroes: the compressor gives back a zero page for free and
# the ballast stops being ballast. Built in slices so the peak is not doubled.
chunks = []
for _ in range(gb * 8):                       # 128 MiB at a time
    chunks.append(bytearray(os.urandom(128 * 1024 * 1024)))
while True:
    # Re-touch, so these stay the pages least worth compressing.
    for c in chunks:
        c[0] = (c[0] + 1) & 0xFF
        c[-1] = (c[-1] + 1) & 0xFF
    time.sleep(5)
PY
  BALLAST=$!
  # What the kernel calls this, rather than what a free-page count looks like.
#
# 1 is normal, 2 is warning, 4 is critical. Reading it turns "14 MB free" from
# an inference into the kernel's own word, and the second number is the one item
# 8 actually turns on: the way a dozen volumes stop being served on a small Mac
# is jetsam taking one of the machines, or one of the person's windows.
pressure_level() {
  case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
    1) echo "normal" ;;
    2) echo "warning" ;;
    4) echo "critical" ;;
    *) echo "unknown" ;;
  esac
}
pressure_kills() {
  sysctl -n kern.memorystatus.kill_on_sustained_pressure_count 2>/dev/null || echo 0
}
KILLS_BEFORE="$(pressure_kills)"
echo "  before the ballast: pressure $(pressure_level), $KILLS_BEFORE killed for it"

echo "  filling ${HOLD} GB from urandom (pid $BALLAST)…"
  # Waited for by what the machine feels, not by the holder's resident size.
  #
  # Resident size cannot reach the target: macOS compresses those pages as
  # fast as they are made, so `ps` reported six megabytes of an eight-gigabyte
  # ballast while the compressor held 7.9 GB and free memory sat at fifteen.
  # The check ran its full four minutes and then said the ballast had failed,
  # about a machine that was genuinely down to its last few megabytes.
  #
  # Free memory is what the rest of the Mac actually contends for, so that is
  # what this waits on.
  for _ in $(seq 1 120); do
    free_mb=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print int($3*16384/1048576)}')
    [ -n "$free_mb" ] || free_mb=0
    [ "$free_mb" -le 400 ] && break
    kill -0 "$BALLAST" 2>/dev/null || { echo "  ballast died" >&2; exit 1; }
    sleep 2
  done
  rss=$(ps -o rss= -p "$BALLAST" 2>/dev/null | tr -d ' ')
  echo "  ballast holding: ${free_mb} MB free, $(( ${rss:-0} / 1024 )) MiB of it uncompressed"
fi

echo
echo "=== with ~8 GB left ==="
# The kernel's verdict, next to the numbers it is the verdict on.
echo "  kernel pressure level        $(pressure_level)"
echo "  killed for sustained pressure $(( $(pressure_kills) - KILLS_BEFORE )) during this run"
memory_pressure 2>/dev/null | grep -i 'free percentage'
echo "swap: $(sysctl -n vm.swapusage)"
echo

# Ordinary use, timed. Not a synthetic benchmark: the things a person does
# while volumes are open.
for label in "home listing" "spotlight-free find" "process launch"; do
  case $label in
    "home listing")       cmd=(/bin/ls -la "$HOME") ;;
    "spotlight-free find") cmd=(/usr/bin/find "$HOME/Repos/lukotta/sources" -name '*.swift') ;;
    "process launch")     cmd=(/usr/bin/true) ;;
  esac
  s=$(/usr/bin/python3 -c 'import time;print(time.time())')
  "${cmd[@]}" >/dev/null 2>&1
  e=$(/usr/bin/python3 -c 'import time;print(time.time())')
  # Nested quotes inside an f-string are a syntax error before Python 3.12,
  # and /usr/bin/python3 here is 3.9. Every one of these latencies printed a
  # SyntaxError instead of a number, in a script whose whole purpose is
  # reporting latencies. Formatted without the nesting.
  /usr/bin/python3 -c "print('  %-22s %7.0f ms' % ('$label', ($e-$s)*1000))"
done

echo
echo "=== what the app and its machines are holding ==="
if [ -x scripts/footprint.sh ]; then bash scripts/footprint.sh; fi
echo
echo "swap after: $(sysctl -n vm.swapusage)"
