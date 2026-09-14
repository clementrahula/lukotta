#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# An open drive is in Finder's sidebar under Favourites, goes when it is ejected in Finder, and comes back when it opens again.
#   ./scripts/drive-is-in-the-sidebar.sh /dev/diskNsM
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEV="${1:?usage: drive-is-in-the-sidebar.sh /dev/diskNsM}"
APP_BUNDLE="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
[ -x "$APP" ] || { echo "no app at $APP"; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | grep -c -- "--drive")" -gt 0 ] \
  || { echo "$APP has no --drive; rebuild with LUKOTTA_DEVTOOLS=1"; exit 2; }
[ -b "$DEV" ] || { echo "$DEV is not a block device"; exit 2; }
HOST="$(basename "$DEV").local"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/favourites.swift" <<'EOF'
import CoreServices
import Foundation
var seed: UInt32 = 0
guard let list = LSSharedFileListCreate(nil, "com.apple.LSSharedFileList.FavoriteItems" as CFString, nil)?
    .takeRetainedValue(),
    let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as NSArray?
else { exit(1) }
for element in items {
    let item = element as! LSSharedFileListItem
    let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
    let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
    let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?
    // A favourite of an ejected volume resolves to nothing and still has its name.
    print("\(name)\t\(url?.path ?? "")")
}
EOF
swiftc -O -o "$WORK/favourites" "$WORK/favourites.swift" 2>/dev/null || { echo "favourites reader did not build"; exit 2; }

# Finder's volume: the AFP one, or the engine's own NFS mount where nothing is hidden behind it.
finder_volume() {
  local afp nfs
  afp="$(mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1)"
  nfs="$(mount | grep -F "$HOST:" | grep ' (nfs' | grep -v nobrowse | sed -E 's/^.* on (.*) \(nfs.*$/\1/' | head -n 1)"
  if [ -n "$afp" ]; then echo "$afp"; else echo "$nfs"; fi
}
# Entries for the drive: resolved to its mount point, or its name with no path once ejected.
copies() {
  "$WORK/favourites" | awk -F '\t' -v path="$1" -v name="$(basename "$1")" \
    '$2 == path || ($1 == name && $2 == "") { n++ } END { print n + 0 }'
}
listed() { [ "$(copies "$1")" -gt 0 ]; }
failed=0
fail() { echo "  FAIL $*"; failed=1; }
ok() { echo "  ok   $*"; }

open_drive() {
  timeout 900 "$APP" --drive open="$DEV" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
  point=""
  for _ in $(seq 1 120); do point="$(finder_volume)"; [ -n "$point" ] && break; sleep 1; done
  [ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }
}

# Every favourite there was before this run, to compare with afterwards.
all_before="$("$WORK/favourites")"

# The app running, as it is whenever somebody has a drive open from its window.
open -a "$APP_BUNDLE"
for _ in $(seq 1 30); do [ -n "$(pgrep -f "${APP}\$")" ] && break; sleep 1; done
[ -n "$(pgrep -f "${APP}\$")" ] || { echo "the app did not start"; exit 2; }

open_drive
sleep 3
if [ "$(copies "$point")" = 1 ]; then ok "the open drive is in the sidebar once, at $point"; else fail "the open drive is in the sidebar $(copies "$point") times"; fi
others() { awk -F '\t' -v path="$point" -v name="$(basename "$point")" '!($2 == path || $1 == name)'; }
before="$(printf '%s\n' "$all_before" | others)"

osascript -e 'on run argv' -e 'tell application "Finder" to eject (disk (item 1 of argv))' -e 'end run' \
  "$(basename "$point")" >/dev/null 2>&1
for _ in $(seq 1 60); do [ -z "$(finder_volume)" ] && break; sleep 1; done
# Only the running app may take it away: nothing else of this run touches the sidebar now.
gone=0
for _ in $(seq 1 20); do listed "$point" || { gone=1; break; }; sleep 1; done
if [ "$gone" = 1 ]; then ok "ejected in Finder, it has left the sidebar"; else fail "the ejected drive is still in the sidebar"; fi
for _ in $(seq 1 60); do [ -z "$(pgrep -f -- "anylinuxfs mount .*${DEV}\$")" ] && break; sleep 1; done
if [ "$("$WORK/favourites" | others)" = "$before" ]; then
  ok "every other favourite is as it was"
else
  fail "other favourites changed"
fi

open_drive
sleep 3
if [ "$(copies "$point")" = 1 ]; then ok "opened again, it is back in the sidebar once"; else fail "opened again, it is in the sidebar $(copies "$point") times"; fi

[ "$failed" = 0 ] && echo "the drive is in the sidebar while it is open" || echo "the sidebar does not follow the drive"
[ "$failed" = 0 ]
