#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Build the disk image a release is downloaded as.
#
# Usage: make-dmg.sh <app> <output.dmg> <name> <version>
#
# A folder holding the app and a link to /Applications, laid out so that the
# window says what to do without a word: drag this onto that. Nothing is
# installed by the image itself, and nothing runs from it.
set -euo pipefail
APP="$1"
OUT="$2"
NAME="$3"
VERSION="$4"

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
rm -f "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

# UDZO is the compressed read-only format every Mac can open, and the one
# Gatekeeper is used to seeing. The volume name is what Finder shows when it is
# mounted, so it carries the version somebody is about to install.
/usr/bin/hdiutil create \
  -volname "$NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -quiet \
  "$OUT"

[ -f "$OUT" ] || { echo "error: no image was produced" >&2; exit 1; }
