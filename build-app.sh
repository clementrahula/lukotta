#!/bin/bash
# Build, sign and install Lukotta.
#
#   ./build-app.sh                 build, sign, install to /Applications
#   BLM_INSTALL=0 ./build-app.sh   build only
#   BLM_SIGN_ID="..." ./build-app.sh
#
# The marketing version comes from ./VERSION (semver). The build number is the
# git commit count, which is monotonic and needs no manual bookkeeping.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Lukotta"
OUT="${1:-$HERE/dist/$APP_NAME.app}"
CONTENTS="$OUT/Contents"

VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "error: VERSION must be semver (found '$VERSION')" >&2; exit 1 ;;
esac
BUILD="$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)"

SIGN_ID="${BLM_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="-"

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/helpers"

# Never build a shippable bundle from a failing tree. BLM_SKIP_TESTS=1 is for
# fast iteration only.
if [ "${BLM_SKIP_TESTS:-0}" != "1" ]; then
  printf 'Running tests…\n'
  "$HERE/tests/run-all.sh" >/dev/null || {
    echo "error: tests failed; refusing to build. Run ./tests/run-all.sh" >&2; exit 1; }
fi

printf 'Building %s %s (build %s)\n' "$APP_NAME" "$VERSION" "$BUILD"
swiftc -parse-as-library \
  -target arm64-apple-macos15.0 \
  -O -whole-module-optimization \
  "$HERE/src/Engine.swift" \
  "$HERE/src/Mounter.swift" \
  "$HERE/src/AppModel.swift" \
  "$HERE/src/ContentView.swift" \
  "$HERE/src/LukottaApp.swift" \
  -o "$CONTENTS/MacOS/$APP_NAME"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
  "$HERE/src/Info.plist" > "$CONTENTS/Info.plist"
cp "$HERE/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$HERE/helpers/validate-key.sh" "$CONTENTS/Resources/helpers/validate-key.sh"
chmod 755 "$CONTENTS/Resources/helpers/validate-key.sh"
cp "$HERE/LICENSE" "$CONTENTS/Resources/LICENSE"
[ -f "$HERE/THIRD_PARTY_NOTICES.md" ] && cp "$HERE/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/"
printf 'APPL????' > "$CONTENTS/PkgInfo"

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
else
  printf 'warning: no vendor/engine - run ./vendor-engine.sh first\n' >&2
fi

printf 'Signing with: %s\n' "$SIGN_ID"
/usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 \
  || /usr/bin/codesign --force --sign "$SIGN_ID" "$OUT" >/dev/null
/usr/bin/codesign --verify --strict "$OUT" && printf 'Signature verified\n'
printf 'Built %s\n' "$OUT"

if [ "${BLM_INSTALL:-1}" = "1" ]; then
  APPS="/Applications/$APP_NAME.app"
  rm -rf "$APPS"
  /usr/bin/ditto "$OUT" "$APPS"
  printf 'Installed %s\n' "$APPS"
fi
