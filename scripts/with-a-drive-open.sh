#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Opens a drive through the app and hands the mount point to something else.
#
# WHY
#
# Several harnesses here take a mounted volume and do their work on it --
# finder-copy-cycles.sh, xattr-forks.sh, flush-latency.sh. Each is right to: a
# harness that also has to open a drive is two things at once and the mounting
# half gets copied badly into every one of them.
#
# But a claim in checks.tsv is a command that runs by itself, and those cannot.
# Registered without their argument they printed a usage line and were recorded
# as failures -- five of the six failures in the first full run were that, and
# they read exactly like something in the app having broken.
#
# So the opening lives here once. Whatever follows is run with the mount point
# as its last argument, and the drive is let go afterwards whatever happens.
#
#   ./scripts/with-a-drive-open.sh ntfs-vectors.img bash scripts/xattr-forks.sh
#   ./scripts/with-a-drive-open.sh ext4-vectors.img bash scripts/flush-latency.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="${OUT:-$HOME/.lukotta-testvols}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"

IMAGE="${1:-}"
shift || true
[ -n "$IMAGE" ] && [ "$#" -gt 0 ] || {
  echo "usage: $0 <image> <command...>   # the mount point is appended" >&2; exit 2; }

IMG="$IMAGE"
[ -f "$IMG" ] || IMG="$OUT/$IMAGE"
[ -f "$IMG" ] || IMG="$OUT/crowd/$IMAGE"
[ -f "$IMG" ] || { echo "error: no image $IMAGE" >&2; exit 2; }
[ -x "$APP" ] || { echo "error: no app at $APP" >&2; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] || {
  echo "error: $APP_BUNDLE has no --drive; build with LUKOTTA_DEVTOOLS=1" >&2; exit 2; }

WORK="$(mktemp -d)"
DEV=""
release() {
  for p in $(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}'); do
    umount -f "$p" >/dev/null 2>&1
  done
  for d in $(hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}'); do
    hdiutil detach "$d" -force -quiet >/dev/null 2>&1
  done
  DEV=""
}
trap 'release; rm -rf "$WORK"' EXIT
release

DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
  2>/dev/null | head -1 | awk '{print $1}')"
[ -n "${DEV:-}" ] || { echo "error: $IMAGE would not attach" >&2; exit 2; }
timeout 300 "$APP" --drive open="$DEV" > "$WORK/open.log" 2>&1 \
  || { echo "error: did not open: $(tail -1 "$WORK/open.log")" >&2; exit 2; }
POINT="$(mount | /usr/bin/grep ':/mnt/' | awk '{print $3}' | head -1)"
[ -n "${POINT:-}" ] || { echo "error: opened and nothing is served" >&2; exit 2; }

echo "opened $IMAGE at $POINT through the app"
"$@" "$POINT"
exit $?
