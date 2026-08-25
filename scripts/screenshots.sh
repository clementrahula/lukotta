#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Draw the main screen for every language, in both appearances.
#
# One picture per language per appearance, of the drive list carrying five
# drives: a BitLocker drive open, another still locked, a LUKS container of
# three volumes, a Btrfs one, and a VDI opened read-only. Every row is made up
# in the app -- nothing is read from this Mac, no drive is attached, and no name
# belongs to anybody, which is the only way to picture a BitLocker drive on a
# Mac that has none.
#
#   ./scripts/screenshots.sh [output-directory]
#
# The app must carry the harnesses, which the released build does not:
#
#   LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=official LUKOTTA_INSTALL=0 ./build-app.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

OUT="${1:-$HERE/dist/screenshots}"
APP="${LUKOTTA_SCREENSHOT_APP:-$HERE/dist/Lukotta.app}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/$(basename "$APP" .app)"
# Looked for by the usage line rather than by the switch itself: a literal of
# fifteen bytes or fewer is compiled into the instruction stream rather than
# stored as text, so grepping for "--screenshots" finds nothing in a build that
# has it.
HARNESS_FOUND="$(LC_ALL=C grep -a -c "usage: --screenshots" "$BINARY-app" || true)"
if [ "${HARNESS_FOUND:-0}" -eq 0 ]; then
  echo "error: $(basename "$APP") was built without the harnesses." >&2
  echo "       LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=official ./build-app.sh" >&2
  exit 1
fi

mkdir -p "$OUT"
# Every language the app is translated into, taken from the translations rather
# than written down here, so a new one is drawn without anybody remembering.
# English is not among them -- it is what they are translated from -- so it is
# named here.
LANGUAGES="en $(find "$HERE/translations" -maxdepth 1 -name '*.json' -exec basename {} .json \; | sort)"

printf 'Drawing the main screen in each language\n'
count=0
for lang in $LANGUAGES; do
  # The region as well as the language: sizes are written the way the reader
  # writes them, so a German picture says 1,4 TB and an English one 1.4 TB.
  "$BINARY" --screenshots "$OUT" \
    -AppleLanguages "($lang)" -AppleLocale "${lang//-/_}" >/dev/null
  count=$((count + 1))
done

printf '  %s languages, two appearances, %s pictures in %s\n' \
  "$count" "$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')" "$OUT"
