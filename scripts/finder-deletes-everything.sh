#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Finder deletes a 2000-file folder from a drive opened in the dev build, three times, with nothing skipped and no dialog.
#   ./scripts/finder-deletes-everything.sh <device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEVICE="${1:?usage: finder-deletes-everything.sh <device>}"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
HOST="$(basename "$DEVICE").local"
[ -x "$APP" ] || { echo "no dev build at $APP"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
/usr/bin/python3 - "$WORK/tree" <<'PY'
import os, sys
for i in range(2000):
    d = os.path.join(sys.argv[1], f"dir-{i // 1000:04d}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"file-{i:07d}.bin"), "wb") as fh:
        fh.write(os.urandom(4096))
PY
cat > "$WORK/windows.swift" <<'EOF'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(all.filter { ($0[kCGWindowOwnerName as String] as? String) == "Finder"
    && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
EOF
swiftc -O -o "$WORK/finder-windows" "$WORK/windows.swift" 2>/dev/null || { echo "window counter did not build"; exit 2; }
finder_volume() { mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1; }

"$APP" --drive open="$DEVICE" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
point=""
for _ in $(seq 1 60); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
[ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }
before="$("$WORK/finder-windows")"
failed=0
for run in 1 2 3; do
  target="$point/deletes-$$-$run"
  /usr/bin/ditto "$WORK/tree" "$target" || { echo "run $run: could not put 2000 files on the drive"; failed=1; break; }
  t0=$(date +%s)
  err="$(osascript -e 'on run argv' -e 'tell application "Finder"' -e 'with timeout of 600 seconds' \
    -e 'delete (POSIX file (item 1 of argv) as alias)' -e 'end timeout' -e 'end tell' -e 'end run' "$target" 2>&1 >/dev/null)"
  left="$(find "$target" -type f 2>/dev/null | wc -l | tr -d ' ')"
  dialogs=$(( $("$WORK/finder-windows") - before ))
  echo "run $run: Finder delete in $(( $(date +%s) - t0 )) s, ${err:-no error}, $left files left, $dialogs new Finder windows"
  if [ -n "$err" ] || [ -e "$target" ] || [ "$dialogs" -gt 0 ]; then failed=1; break; fi
done
"$APP" --drive eject="$DEVICE" >/dev/null 2>&1
[ "$failed" = 0 ]
