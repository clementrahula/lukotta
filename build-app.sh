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

  # Sign inside-out: every nested Mach-O first, then the bundle. The engine
  # needs the hypervisor entitlement to start its microVM; the Linux rootfs is
  # data and is left alone.
  ENGINE="$CONTENTS/Resources/engine"
  printf 'Signing embedded engine…\n'
  /usr/bin/find "$ENGINE/anylinuxfs" -type f -print0 | while IFS= read -r -d "" f; do
    /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -q "Mach-O" || continue
    case "$f" in
      */bin/anylinuxfs)
        /usr/bin/codesign --force --options runtime \
          --entitlements "$HERE/anylinuxfs.entitlements" \
          --sign "$SIGN_ID" "$f" >/dev/null 2>&1 \
          || { printf "error: could not sign %s\n" "$f" >&2; exit 1; }
        ;;
      *)
        /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$f" >/dev/null 2>&1 \
          || /usr/bin/codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
        ;;
    esac
  done
fi

printf 'Signing with: %s\n' "$SIGN_ID"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 \
  || /usr/bin/codesign --force --sign "$SIGN_ID" "$OUT" >/dev/null

/usr/bin/codesign --verify --strict "$OUT" && printf 'Signature verified\n'
printf 'Built %s\n' "$OUT"

# Install into /Applications unless told otherwise. macOS grants Full Disk
# Access per app signature and location, and an app buried in a build directory
# is both awkward to find in the settings picker and easy to invalidate.
if [ "${BLM_INSTALL:-1}" = "1" ]; then
  APPS="/Applications/BitLocker Mounter.app"
  rm -rf "$APPS"
  /usr/bin/ditto "$OUT" "$APPS"
  printf 'Installed %s\n' "$APPS"
fi
