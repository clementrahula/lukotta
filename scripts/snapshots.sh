#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Render every screen and compare it with what it looked like before.
#
#   ./scripts/snapshots.sh            check against the recorded baselines
#   ./scripts/snapshots.sh --look     draw into a temporary directory and stop
#   ./scripts/snapshots.sh --look hu  the same, in one language
#   ./scripts/snapshots.sh --record   replace the baselines with what it draws now
#
# Recording is deliberately a separate command. A harness that quietly updates
# its own baselines reports success no matter what it drew.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$HERE/tests/snapshots"
# The unbranded build, always. The header draws the app's own name and icon,
# so baselines belong to one branding, and the unbranded one is what
# ./build-app.sh produces by default and what anyone with a clone can make.
APP="${LUKOTTA_SNAPSHOT_APP:-$HERE/dist/Drive Unlocker.app}"
[ -d "$APP" ] || {
  echo "error: no unbranded app at $APP; run ./build-app.sh first" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/$(basename "$APP" .app)"

# Looking is not recording. A screen under review changes several times before
# it is right, and recording after each one rewrites baselines nobody has
# agreed to yet. This draws the screens and leaves the baselines alone.
if [ "${1:-}" = "--look" ]; then
  LOOK="${TMPDIR:-/tmp}/lukotta-look"
  rm -rf "$LOOK"; mkdir -p "$LOOK"
  if [ -n "${2:-}" ]; then
    "$BINARY" --snapshots "$LOOK" -AppleLanguages "($2)" >/dev/null
  else
    "$BINARY" --snapshots "$LOOK" >/dev/null
  fi
  echo "  drew $(find "$LOOK" -name '*.png' | wc -l | tr -d ' ') screens in $LOOK"
  echo "  nothing recorded"
  exit 0
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$BINARY" --snapshots "$OUT" >/dev/null

# German as well as English. macOS ignores dynamicTypeSize, so the way text
# outgrowing its room actually shows up here is a translation: German runs a
# third longer than English and compounds rather than wrapping. Anything that
# survives it survives the other twenty.
GERMAN="$OUT/de"
mkdir -p "$GERMAN"
"$BINARY" --snapshots "$GERMAN" -AppleLanguages "(de)" >/dev/null
for f in "$GERMAN"/*.png; do mv "$f" "$OUT/de-$(basename "$f")"; done
rmdir "$GERMAN"

if [ "${1:-}" = "--record" ]; then
  # One screen is eight baselines: two languages, two sizes, two appearances.
  # More than two screens' worth means the change was not to a screen but to
  # something every screen has -- a window size, the header, a shared control.
  # That is a real answer sometimes, and it is never an accidental one, so it
  # has to be asked for.
  SPREAD=16
  changed=0
  for f in "$OUT"/*.png; do
    cmp -s "$f" "$BASELINE/$(basename "$f")" || changed=$((changed + 1))
  done
  if [ "$changed" -gt "$SPREAD" ] && [ "${2:-}" != "--all" ]; then
    echo "error: $changed baselines would change, more than the $SPREAD a screen or two accounts for." >&2
    echo "       If that is meant -- a window size, the header, something every screen has --" >&2
    echo "       say so: ./scripts/snapshots.sh --record --all" >&2
    echo "       To look without recording: ./scripts/snapshots.sh --look" >&2
    exit 1
  fi
  mkdir -p "$BASELINE"
  rm -f "$BASELINE"/*.png
  cp "$OUT"/*.png "$BASELINE/"
  echo "  recorded $(find "$BASELINE" -name '*.png' | wc -l | tr -d ' ') baselines, $changed of them changed"
  exit 0
fi

swift "$HERE/scripts/compare-snapshots.swift" "$BASELINE" "$OUT"
