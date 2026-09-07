#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Item 3, which is the one a successful copy cannot prove.
#
#   bash scripts/with-a-drive-open.sh ntfs-vectors.img bash scripts/nothing-user-visible.sh
#
# "Nothing user-visible during a copy: no stall, no error dialog, no Finder
# complaint, no 'some items had to be skipped'." A copy that finishes having
# shown a dialog on the way has failed that, and nothing in a byte count says
# so. `watch-for-complaints.sh` was written for exactly this and was wired to
# no row: item 3's row ran the poisoned-name check instead, which is a real
# claim about a different thing. So the copy that item 2 drives through Finder
# is run again here with the watcher beside it, and the watcher decides.
#
# The channel is proved open first. A count of zero has two causes -- nothing
# complained, or nothing was listening -- and only one of them is a pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

bash scripts/watch-for-complaints.sh --probe || {
  echo "the kernel channel is shut; a zero from the watcher would mean nothing" >&2
  exit 1
}

MOUNT="$(mount | awk '/:\/mnt\// {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}')"
[ -n "$MOUNT" ] || { echo "no engine mount; open a drive first" >&2; exit 2; }
echo "copying through Finder onto $MOUNT, with the watcher beside it"

# Long enough to outlast the copy, and stopped as soon as the copy ends: the
# watcher runs for its whole duration otherwise, and a row that waits an hour
# for a copy that took four minutes is a row nobody runs.
WATCH="${TMPDIR:-/tmp}/lukotta-nothing-visible.log"
bash scripts/watch-for-complaints.sh 3600 "$MOUNT" > "$WATCH" 2>&1 &
watcher=$!
trap 'kill "$watcher" 2>/dev/null' EXIT

CYCLES="${CYCLES:-3}" bash scripts/finder-copy-cycles.sh
copy=$?

# INT rather than KILL, so the watcher reaches its own verdict on what it saw
# rather than being cut off before it can report.
kill -INT "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
said=$?
trap - EXIT

echo
cat "$WATCH"

echo
if [ "$copy" -ne 0 ]; then
  echo "RESULT: the copy itself failed" >&2
  exit 1
fi
if [ "$said" -ne 0 ]; then
  echo "RESULT: the copy finished, and something reached the person" >&2
  exit 1
fi
echo "RESULT: the copy finished and nothing reached the person"
