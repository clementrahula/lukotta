#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# How long after a copy the files can be seen.
#
# WHY
#
# On 2026-09-03 one volume of twelve came back with an empty directory after a
# copy that had written sixty files onto it. Nothing was lost -- the files were
# there a minute later -- but a person who copies a folder and opens it sees an
# empty folder, which is the copying trouble item 3 forbids. It happened once
# in three runs of the twelve-volume harness, and each of those runs costs four
# minutes to reach the copy.
#
# This does the copy part alone, over and over, against volumes that are
# already open, so an intermittent fault is caught in minutes instead of hours.
# It records for each volume the moment the copy returned and the moment the
# last file became visible, and it takes the directory's own mtime at the
# instant the listing was short -- because that is what says who is at fault.
# A directory whose mtime already covers the copy while its listing is empty is
# a stale readdir cache on this Mac; a directory whose mtime predates the copy
# is a server that has not made the files yet. The two need different fixes.
#
#   ./scripts/copy-visibility.sh          # 20 cycles over every open CROWD
#   CYCLES=100 ./scripts/copy-visibility.sh
#   FILES=200 ./scripts/copy-visibility.sh
set -uo pipefail

CYCLES="${CYCLES:-20}"
FILES="${FILES:-60}"

mount | /usr/bin/grep -oE '/Volumes/CROWD[0-9]+' | sort -u > /tmp/.cv-points
count=$(/usr/bin/grep -c . < /tmp/.cv-points)
[ "$count" -gt 0 ] || {
  echo "error: no CROWD volumes are open; open them with crowd-through-the-app.sh" >&2
  exit 2
}

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
for i in $(seq 1 "$FILES"); do head -c 100000 /dev/urandom > "$SRC/f$i.bin"; done

echo "$count volumes open, $CYCLES cycles of $FILES files onto each at once"

/usr/bin/python3 - "$SRC" "$CYCLES" "$FILES" <<'MEASURE'
import os, subprocess, sys, time

src, cycles, files = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
points = [p.strip() for p in open("/tmp/.cv-points") if p.strip()]

late = []          # every copy that was not immediately visible
worst = 0.0
for cycle in range(1, cycles + 1):
    dest = "copyvis%d" % cycle
    procs = {}
    began = time.perf_counter()
    for p in points:
        d = os.path.join(p, dest)
        procs[p] = subprocess.Popen(["/usr/bin/ditto", src, d],
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
    for p, proc in procs.items():
        out = proc.communicate()[0]
        if proc.returncode != 0:
            print("  cycle %d: the copy onto %s failed: %s"
                  % (cycle, p, out.strip()[:200]))

    # The copy has returned everywhere. From here on, anything not visible is
    # invisible to a person who opens the folder right now.
    copied = time.perf_counter()
    pending = list(points)
    while pending and time.perf_counter() - copied < 180:
        for p in list(pending):
            d = os.path.join(p, dest)
            try:
                n = len(os.listdir(d))
            except OSError as e:
                n = -e.errno
            if n >= files:
                pending.remove(p)
                continue
            # Short. Take the directory's own mtime before moving on: it says
            # whether this Mac is holding an old listing of a directory it can
            # already see is new.
            try:
                mtime = os.stat(d).st_mtime
                age = time.time() - mtime
            except OSError:
                age = None
            waited = time.perf_counter() - copied
            if waited > 0.5:
                late.append((cycle, p, n, waited, age))
        time.sleep(0.05)

    for p in pending:
        d = os.path.join(p, dest)
        try: n = len(os.listdir(d))
        except OSError as e: n = -e.errno
        print("  cycle %d: %s still shows %s of %d after 180 s"
              % (cycle, p, n, files))

    took = time.perf_counter() - copied
    worst = max(worst, took)
    for p in points:
        try: subprocess.run(["/bin/rm", "-rf", os.path.join(p, dest)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception: pass
    print("  cycle %2d: copied in %5.1f s, all visible %.0f ms after"
          % (cycle, copied - began, took * 1000))

print()
if not late:
    print("RESULT: every copy was fully visible the instant it returned, "
          "%d cycles x %d volumes" % (cycles, len(points)))
else:
    seen = {}
    for cycle, p, n, waited, age in late:
        k = (cycle, p)
        if k not in seen or waited > seen[k][1]:
            seen[k] = (n, waited, age)
    print("RESULT: %d of %d copies were not visible when they returned"
          % (len(seen), cycles * len(points)))
    for (cycle, p), (n, waited, age) in sorted(seen.items()):
        print("  cycle %d %s: showed %s files, still short %.1f s later, "
              "directory mtime %s"
              % (cycle, p, n, waited,
                 "%.1f s old" % age if age is not None else "unreadable"))
print("worst wait for a copy to become visible: %.0f ms" % (worst * 1000))
MEASURE
