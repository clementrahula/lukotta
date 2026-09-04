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

# What earlier harnesses left on the fixture, before handing it over.
#
# These volumes are shared by every harness here and each leaves its corpus
# behind. copy-torture.sh then found 765 MB free where it needs 1089 and
# refused -- reported as a failing claim about the app, on a fixture with two
# gigabytes of room and most of it full of other runs' test data.
#
# Only names these scripts make. Nothing else is touched, so a fixture that
# holds something deliberate keeps it.
for leftover in vec-awkward vec-full vec-perms vec-power vec-conc vec-cycle \
                crowd-write xattr-forks-test copy-torture-test big damaged \
                damaged2 spill fill first-write fork-probe rf probe; do
  # ${POINT:?} rather than $POINT: an empty mount point would make this
  # "rm -rf /vec-awkward", and one of these lists is all it takes.
  rm -rf "${POINT:?}/$leftover" >/dev/null 2>&1
done
rm -rf "${POINT:?}"/copyvis* "${POINT:?}"/.lukotta-unreadable-* >/dev/null 2>&1

echo "opened $IMAGE at $POINT through the app"
echo "  $(df -m "$POINT" | tail -1 | awk '{print $4}') MB free after clearing earlier runs"
"$@" "$POINT"
exit $?
