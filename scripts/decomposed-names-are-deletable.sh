#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A file whose name is stored decomposed is listed, resolved and deleted, and its folder goes with it.
#   ./scripts/decomposed-names-are-deletable.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: decomposed-names-are-deletable.sh <device>}"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$APP" ] || { echo "no dev build at $APP"; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | grep -c -- "--drive")" -gt 0 ] \
  || { echo "$APP has no --drive; rebuild with LUKOTTA_DEVTOOLS=1"; exit 2; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }

timeout 900 "$APP" --drive open="$DEVICE" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
point=""
for _ in $(seq 1 240); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
[ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }

# A name Finder stores decomposed, which is every name a Mac writes: the volume
# keeps the bytes it was given, and a client that composes them on the way back
# asks for a name that is not there.
/usr/bin/python3 - "$point" <<'PY'
import os, sys, unicodedata
point = sys.argv[1]
folder = os.path.join(point, "decomposed-probe")
name = unicodedata.normalize("NFD", "jõel-Ноты.pdf")
# Written underneath, where the name is stored as it is given. Writing it
# through the share would be no test at all: the server composes on the way
# in, so the volume would hold the composed name and the case never arises.
hidden = os.path.join("/Volumes/.lukotta", os.path.basename(point), "decomposed-probe")
os.makedirs(hidden, exist_ok=True)
with open(os.path.join(hidden, name), "wb") as fh:
    fh.write(b"x" * 32)
if not os.path.isdir(folder):
    print("the folder written underneath is not in the share"); raise SystemExit(1)
listed = os.listdir(folder)
if not listed:
    print("the file was not listed at all"); raise SystemExit(1)
stored = listed[0]
faults = []
if unicodedata.normalize("NFC", stored) == stored:
    faults.append("the volume composed the name on the way in")
p = os.path.join(folder, stored)
if not os.path.exists(p):
    faults.append(f"listed but does not resolve: {stored!r}")
else:
    try:
        os.remove(p)
    except OSError as e:
        faults.append(f"could not delete it: {e.strerror}")
if not faults:
    try:
        os.rmdir(folder)
    except OSError as e:
        faults.append(f"its folder would not go: {e.strerror}")
for f in faults:
    print(" ", f)
print("decomposed name held and deleted" if not faults else "decomposed names are not deletable")
raise SystemExit(1 if faults else 0)
PY
rc=$?
timeout 300 "$APP" --drive eject="$DEVICE" >/dev/null 2>&1
exit "$rc"
