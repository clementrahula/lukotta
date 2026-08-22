#!/bin/bash
# Build, sign and install Lukotta.
#
#   ./build-app.sh                 build, sign, install to /Applications
#   LUKOTTA_INSTALL=0 ./build-app.sh   build only
#   LUKOTTA_SIGN_ID="..." ./build-app.sh
#   LUKOTTA_NOTARY_PROFILE="name" ./build-app.sh   also notarise and staple
#   LUKOTTA_BRANDING=official ./build-app.sh        build as Lukotta
#
# Builds are unbranded by default. The Lukotta name, wordmark and logo are
# trademarks and are not licensed under the GPL, so a build carries them only
# when asked. Reproducing a published release requires official branding, which
# is permitted; distributing the result under that name is not. The software is
# GPL either way. See TRADEMARKS.txt.
#
# Signing establishes who built it. Notarising is a separate round trip to
# Apple, without which Gatekeeper refuses the app on every Mac except the one
# that built it. It is opt-in by naming a notarytool keychain profile, since it
# needs an Apple ID and an app-specific password stored beforehand:
#
#   xcrun notarytool store-credentials "name" --apple-id ID --team-id TEAM
#
# The marketing version comes from ./VERSION (semver). The build number is the
# git commit count, which is monotonic and needs no manual bookkeeping.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Everything the trademark covers, in one place. The unbranded identifier uses
# example.com, reserved by RFC 2606, so it cannot collide with a real vendor and
# is recognisable as a placeholder.
case "${LUKOTTA_BRANDING:-unbranded}" in
  official)
    APP_NAME="Lukotta"
    BUNDLE_ID="com.clementrahula.lukotta"
    ICON_SET="AppIcon"
    MARK_SET="LukottaMark"
    HELPER_NAME="LukottaHelper"
    ;;
  unbranded)
    APP_NAME="Drive Unlocker"
    BUNDLE_ID="com.example.driveunlocker"
    ICON_SET="AppIconUnbranded"
    MARK_SET="MarkUnbranded"
    HELPER_NAME="UnlockHelper"
    ;;
  *)
    echo "error: LUKOTTA_BRANDING must be 'official' or 'unbranded'" >&2; exit 1 ;;
esac

OUT="${1:-$HERE/dist/$APP_NAME.app}"
CONTENTS="$OUT/Contents"

VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "error: VERSION must be semver (found '$VERSION')" >&2; exit 1 ;;
esac
BUILD="$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)"

SIGN_ID="${LUKOTTA_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="-"

# A shippable bundle is never built from a failing tree. LUKOTTA_SKIP_TESTS=1 is
# for iteration only.
if [ "${LUKOTTA_SKIP_TESTS:-0}" != "1" ]; then
  printf 'Running tests…\n'
  swift run -c release LukottaTests >/dev/null || {
    echo "error: tests failed; refusing to build. Run: swift run LukottaTests" >&2; exit 1; }
fi

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/helpers"

printf 'Building %s %s (build %s)\n' "$APP_NAME" "$VERSION" "$BUILD"
swift build -c release --product Lukotta
cp "$(swift build -c release --product Lukotta --show-bin-path)/Lukotta" \
   "$CONTENTS/MacOS/$APP_NAME"

# SwiftPM links frameworks by @rpath but emits rpaths pointing into its own
# build tree. Inside a bundle they live in Contents/Frameworks, so the loader
# needs to be told. Without this the app fails to launch at all.
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

# The privileged helper, registered with SMAppService so unlocking does not need
# an administrator password every time.
swift build -c release --product LukottaHelper
cp "$(swift build -c release --product LukottaHelper --show-bin-path)/LukottaHelper" \
   "$CONTENTS/MacOS/$HELPER_NAME"
mkdir -p "$CONTENTS/Library/LaunchDaemons"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__HELPER_NAME__|$HELPER_NAME|" \
  "$HERE/resources/helper.plist" \
  > "$CONTENTS/Library/LaunchDaemons/$BUNDLE_ID.helper.plist"

# Sparkle ships as a framework and must be embedded and signed inside the
# bundle. Its XCFramework is resolved by SwiftPM; take the built slice.
SPARKLE="$(find "$HERE/.build/artifacts" -name Sparkle.framework -path "*macos-arm64*" -print -quit 2>/dev/null)"
if [ -n "$SPARKLE" ]; then
  mkdir -p "$CONTENTS/Frameworks"
  /usr/bin/ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
  printf 'Embedded Sparkle\n'
fi

# The Sparkle public key is generated once with scripts/sparkle-keys.sh and set
# in the environment (or a local file). Without it the app still builds and
# runs; it simply cannot verify an update, so it must not pretend it can.
SPARKLE_KEY="${LUKOTTA_SPARKLE_PUBLIC_KEY:-$(cat "$HERE/.sparkle-public-key" 2>/dev/null || true)}"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s|__SPARKLE_PUBLIC_KEY__|${SPARKLE_KEY}|" \
    -e "s|__APP_NAME__|$APP_NAME|" -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
    -e "s|__ICON_SET__|$ICON_SET|" -e "s|__MARK_SET__|$MARK_SET|" \
  "$HERE/sources/Info.plist" > "$CONTENTS/Info.plist"
if [ -z "$SPARKLE_KEY" ]; then
  /usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
  printf 'note: no Sparkle key set — updates disabled in this build\n'
fi
# Compile the asset catalogue. SwiftPM's command line copies a .xcassets
# directory rather than building it, and an uncompiled catalogue cannot be
# loaded, so actool does it — the same tool Xcode would use.
ACTOOL="$(xcrun --find actool 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/usr/bin/actool)"
[ -x "$ACTOOL" ] || { echo "error: actool not found; Xcode is required to build the asset catalogue" >&2; exit 1; }
"$ACTOOL" "$HERE/sources/Lukotta/Assets.xcassets" \
  --compile "$CONTENTS/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --app-icon "$ICON_SET" --output-partial-info-plist /dev/null >/dev/null
[ -f "$CONTENTS/Resources/Assets.car" ] || { echo "error: actool produced no Assets.car" >&2; exit 1; }
cp "$HERE/resources/helpers/validate-key.sh" "$CONTENTS/Resources/helpers/validate-key.sh"
chmod 755 "$CONTENTS/Resources/helpers/validate-key.sh"
cp "$HERE/LICENSE.txt" "$CONTENTS/Resources/LICENSE.txt"
# Localisation. The catalogue is the source; xcstringstool turns it into the
# .lproj tables macOS looks for, one per language. macOS then picks by the
# user's language order and falls back to the development region, so a language
# that is missing or half-finished shows English rather than keys.
XCSTRINGS="$(xcrun --find xcstringstool 2>/dev/null \
  || echo /Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool)"
if [ -f "$HERE/resources/Localizable.xcstrings" ]; then
  [ -x "$XCSTRINGS" ] || {
    echo "error: xcstringstool not found; Xcode is required to build the string catalogue" >&2
    exit 1
  }
  "$XCSTRINGS" compile --output-directory "$CONTENTS/Resources" \
    "$HERE/resources/Localizable.xcstrings" >/dev/null
  [ -d "$CONTENTS/Resources/en.lproj" ] || {
    echo "error: xcstringstool produced no tables" >&2; exit 1; }
fi
# Anything hand-written alongside it.
for lproj in "$HERE"/resources/*.lproj; do
  [ -d "$lproj" ] || continue
  /usr/bin/ditto "$lproj" "$CONTENTS/Resources/$(basename "$lproj")"
done
[ -f "$HERE/THIRD_PARTY_NOTICES.md" ] && cp "$HERE/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/"
# Shown in the app beside the notices, so it travels with them.
[ -f "$HERE/SPECS.md" ] && cp "$HERE/SPECS.md" "$CONTENTS/Resources/"
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
          --entitlements "$HERE/lukotta.entitlements" \
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

if [ -d "$CONTENTS/Frameworks/Sparkle.framework" ]; then
  for nested in "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc \
                "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
                "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Updater.app"; do
    [ -e "$nested" ] || continue
    /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$nested" >/dev/null 2>&1 || true
  done
  /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" \
    "$CONTENTS/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
fi

# The helper is a separate executable and must be signed in its own right.
if [ -f "$CONTENTS/MacOS/$HELPER_NAME" ]; then
  /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" \
    "$CONTENTS/MacOS/$HELPER_NAME" >/dev/null 2>&1 || true
fi

printf 'Signing with: %s\n' "$SIGN_ID"
/usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 \
  || /usr/bin/codesign --force --sign "$SIGN_ID" "$OUT" >/dev/null
/usr/bin/codesign --verify --strict "$OUT" && printf 'Signature verified\n'

NOTARY_PROFILE="${LUKOTTA_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" != "-" ]; then
  printf 'Notarising as profile "%s"…\n' "$NOTARY_PROFILE"
  ZIP="$(dirname "$OUT")/$APP_NAME-notarise.zip"
  rm -f "$ZIP"
  # ditto keeps the signature intact; zip(1) does not.
  /usr/bin/ditto -c -k --keepParent "$OUT" "$ZIP"
  if /usr/bin/xcrun notarytool submit "$ZIP" \
      --keychain-profile "$NOTARY_PROFILE" --wait; then
    # Stapling puts the ticket inside the bundle, so a first launch works
    # without asking Apple — which matters on a machine that is offline.
    /usr/bin/xcrun stapler staple "$OUT"
    /usr/sbin/spctl -a -vv -t install "$OUT" 2>&1 | sed 's/^/  /'
  else
    printf 'error: notarisation failed; the build is signed but not notarised\n' >&2
    rm -f "$ZIP"
    exit 1
  fi
  rm -f "$ZIP"
fi
printf 'Built %s\n' "$OUT"

if [ "${LUKOTTA_INSTALL:-1}" = "1" ]; then
  APPS="/Applications/$APP_NAME.app"
  rm -rf "$APPS"
  /usr/bin/ditto "$OUT" "$APPS"
  # Renaming an app at the same path leaves Dock and Finder showing the icon
  # cached under the old name, which looks like a build failure and is not.
  touch "$APPS"
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [ -x "$LSREG" ] && "$LSREG" -f "$APPS" >/dev/null 2>&1 || true
  printf 'Installed %s\n' "$APPS"
fi
