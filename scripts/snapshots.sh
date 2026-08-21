#!/bin/bash
# Render every screen and compare it with what it looked like before.
#
#   ./scripts/snapshots.sh            check against the recorded baselines
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

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$BINARY" --snapshots "$OUT" >/dev/null

if [ "${1:-}" = "--record" ]; then
  mkdir -p "$BASELINE"
  rm -f "$BASELINE"/*.png
  cp "$OUT"/*.png "$BASELINE/"
  echo "  recorded $(find "$BASELINE" -name '*.png' | wc -l | tr -d ' ') baselines"
  exit 0
fi

swift "$HERE/scripts/compare-snapshots.swift" "$BASELINE" "$OUT"
