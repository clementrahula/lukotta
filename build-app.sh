#!/bin/bash
# Build the native BitLocker Mounter app.
#
#   ./build-app.sh              build and sign
#   BLM_SIGN_ID="..." ./build-app.sh   sign with a specific identity
#
# Signing falls back to ad-hoc when no Developer ID is available.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist/BitLocker Mounter.app}"
CONTENTS="$OUT/Contents"

SIGN_ID="${BLM_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="-"

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/helpers"

printf 'Compiling…\n'
swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  -O -whole-module-optimization \
  "$HERE/src/Engine.swift" \
  "$HERE/src/Mounter.swift" \
  "$HERE/src/AppModel.swift" \
  "$HERE/src/ContentView.swift" \
  "$HERE/src/BitLockerMounterApp.swift" \
  -o "$CONTENTS/MacOS/BitLockerMounter"

cp "$HERE/src/Info.plist" "$CONTENTS/Info.plist"
cp "$HERE/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$HERE/helpers/validate-key.sh" "$CONTENTS/Resources/helpers/validate-key.sh"
cp "$HERE/helpers/alfs-proxy.sh" "$CONTENTS/Resources/helpers/alfs-proxy.sh"
chmod 755 "$CONTENTS/Resources/helpers/"*.sh
printf 'APPL????' > "$CONTENTS/PkgInfo"

# The engine is embedded by vendor-engine.sh; when it has not been run the app
# falls back to a locally installed runtime, which is only useful for development.
if [ -d "$HERE/vendor/engine" ]; then
  printf 'Embedding engine…\n'
  /usr/bin/ditto "$HERE/vendor/engine" "$CONTENTS/Resources/engine"
fi

printf 'Signing with: %s\n' "$SIGN_ID"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 \
  || /usr/bin/codesign --force --sign "$SIGN_ID" "$OUT" >/dev/null

/usr/bin/codesign --verify --strict "$OUT" && printf 'Signature verified\n'
printf 'Built %s\n' "$OUT"
