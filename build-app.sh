#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Build, sign and install Lukotta.
#
#   ./build-app.sh                 build, sign, install to /Applications
#   LUKOTTA_INSTALL=0 ./build-app.sh   build only
#   LUKOTTA_SIGN_ID="..." ./build-app.sh
#   LUKOTTA_NOTARY_PROFILE="name" ./build-app.sh   also notarise and staple
#   LUKOTTA_BRANDING=official ./build-app.sh        build as Lukotta
#   LUKOTTA_BRANDING=beta ./build-app.sh            build the pre-release
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
    BUNDLE_ID="com.lukotta"
    ICON_SET="AppIcon"
    MARK_SET="LukottaMark"
    SWITCH_SET="FullDiskAccessSwitch"
    HELPER_NAME="LukottaHelper"
    FEED_URL="https://updates.lukotta.com/appcast.xml"
    ;;
  beta)
    # The release everybody else will get, a week early. Its own identifier,
    # its own daemon, its own saved passphrases and its own feed, so it can sit
    # beside the released app without either one standing on the other -- and
    # everything else about it, including the name and the mark, is the app
    # people will receive.
    APP_NAME="Lukotta Beta"
    BUNDLE_ID="com.lukotta.beta"
    # The mark with a band across its foot: the two sit in the same Dock, and
    # a fault reported against the wrong one costs an evening.
    ICON_SET="AppIconBeta"
    MARK_SET="LukottaMark"
    SWITCH_SET="FullDiskAccessSwitch"
    HELPER_NAME="LukottaBetaHelper"
    # A path on the release feed's own domain rather than a subdomain of its
    # own. A GitHub Pages site carries exactly one custom domain, so a second
    # hostname would mean a second repository, a second certificate and a
    # second thing to notice when it expires -- for a file.
    FEED_URL="https://updates.lukotta.com/beta/appcast.xml"
    ;;
  unbranded)
    APP_NAME="Drive Unlocker"
    BUNDLE_ID="com.example.driveunlocker"
    ICON_SET="AppIconUnbranded"
    MARK_SET="MarkUnbranded"
    SWITCH_SET="FullDiskAccessSwitchUnbranded"
    HELPER_NAME="UnlockHelper"
    FEED_URL="https://updates.lukotta.com/appcast.xml"
    ;;
  *)
    echo "error: LUKOTTA_BRANDING must be 'official', 'beta' or 'unbranded'" >&2; exit 1 ;;
esac

OUT="${1:-$HERE/dist/$APP_NAME.app}"
CONTENTS="$OUT/Contents"

# LUKOTTA_VERSION overrides the file, and only the release script sets it: a
# beta is a pre-release of the version being worked towards, and the suffix is
# worked out there from what has actually been published. Without this the
# bundle said 1.21.0 while the feed, the tag and the release all said
# 1.21.0-beta.1 -- the About sheet naming a version that does not exist.
VERSION="${LUKOTTA_VERSION:-$(tr -d ' \n' < "$HERE/VERSION")}"
# Digits and dots only. The shell glob this used to be accepted "1x.2.3" and
# "1..", because * matches anything, and a version like that reaches the
# appcast and every installed copy before anybody reads it.
# Semver, with the pre-release part allowed: a beta is 1.20.1-beta.1 and the
# release it leads to is 1.20.1. Digits and dots only in the first three, so
# "1x.2.3" and "1.." are still refused -- a version like that reaches the
# appcast and every installed copy before anybody reads it.
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$' || {
  echo "error: VERSION must be semver, optionally with a pre-release" >&2
  echo "       (found '$VERSION'; wanted 1.20.1 or 1.20.1-beta.1)" >&2; exit 1; }

# The lowest macOS this build can run on comes from the engine, not from a
# number typed into the plist. libblkid is taken from a Homebrew bottle and
# carries that bottle's own minimum, so a bottle built for a newer macOS makes
# the app refuse to load on everything below it — while the plist still
# advertised 15.0 and Software Update still offered it.
MIN_MACOS="$(/usr/bin/python3 "$HERE/scripts/lowest-macos.py" "$HERE/vendor/engine.lock")" \
  || exit 1
# LUKOTTA_BUILD overrides it, which only the update harness does: proving an
# update works needs two builds of the same tree, and the commit count cannot
# tell them apart.
BUILD="${LUKOTTA_BUILD:-$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)}"
# The build number is the commit count, so an uncommitted change produces a
# second, different binary claiming the number the last one already has. The
# rollback record keys on that number, and Sparkle compares it. Said out loud
# rather than left to be discovered by a build that behaves unlike its twin.
if ! git -C "$HERE" diff --quiet HEAD 2>/dev/null; then
  printf 'note: uncommitted changes — build %s is already taken by the last build\n' "$BUILD"
fi

# The team identifier, taken from the signing identity rather than written
# down. SMJobBless checks a requirement in each direction -- the app says which
# helper it will bless, the helper says which app may bless it -- and both name
# the team. Nothing of the owner's is in the repository: this is read from
# whatever identity is signing, so a fork pins to its own.
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
# The harnesses go into no build anybody is given.
#
# They were in everything except the release, which stopped describing the beta
# the moment the beta went to other people: it carried --e2e, --snapshots and
# --update-test, and the last of those points at any feed it is handed. Sparkle
# still checks the signature of whatever arrives, so this was surface rather
# than a hole, but a pre-release is an app somebody else runs.
#
# LUKOTTA_DEVTOOLS=1 puts them back, which is what the harnesses do when they
# build the copies they drive.
if [ "${LUKOTTA_DEVTOOLS:-0}" = "1" ]; then
  DEVTOOLS=(-Xswiftc -DDEVTOOLS)
elif [ "${LUKOTTA_BRANDING:-unbranded}" = "unbranded" ]; then
  DEVTOOLS=(-Xswiftc -DDEVTOOLS)
else
  DEVTOOLS=()
fi

# The app is the bundle's executable, and nothing stands in front of it. It
# used to: a C launcher that counted the attempt and handed over with execv.
# macOS gives no menu bar item to a process whose running image is not the
# executable the bundle declares, so the item was created, registered, and
# never laid out.
swift build -c release --product Lukotta ${DEVTOOLS[@]+"${DEVTOOLS[@]}"}
cp "$(swift build -c release --product Lukotta ${DEVTOOLS[@]+"${DEVTOOLS[@]}"} --show-bin-path)/Lukotta" \
   "$CONTENTS/MacOS/$APP_NAME"

# That launcher's job, beside the app rather than in front of it: it is started
# as the app hands over to Sparkle's installer, outlives it, and puts the
# previous version back if the one that arrives will not load. See
# sources/LukottaLaunch/main.c.
swift build -c release --product LukottaLaunch >/dev/null
cp "$(swift build -c release --product LukottaLaunch --show-bin-path)/LukottaLaunch" \
   "$CONTENTS/MacOS/update-check"

# What the binary will actually load on, against what the plist promises. These
# come from two places — Package.swift's platform and the engine's bottle — and
# nothing else notices when they part company.
BINARY_MIN="$(/usr/bin/otool -l "$CONTENTS/MacOS/$APP_NAME" \
  | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
if [ -n "$BINARY_MIN" ] && [ "$BINARY_MIN" != "$MIN_MACOS" ]; then
  echo "error: the binary loads on macOS $BINARY_MIN but the engine needs $MIN_MACOS." >&2
  echo "  Set the platform in Package.swift to match vendor/engine.lock's bottle." >&2
  exit 1
fi

# SwiftPM links frameworks by @rpath but emits rpaths pointing into its own
# build tree. Inside a bundle they live in Contents/Frameworks, so the loader
# needs to be told. Without this the app fails to launch at all.
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

# Checked rather than assumed: without the rpath the app does not start at all,
# and what notices that is the update watcher, which would put the previous
# version back -- reading as an update that undoes itself.
/usr/bin/otool -l "$CONTENTS/MacOS/$APP_NAME" \
  | grep -q "@executable_path/../Frameworks" || {
    echo "error: the app binary cannot find Contents/Frameworks" >&2; exit 1; }

# The privileged helper.
#
# Installed by SMJobBless, which asks for an administrator password once and
# runs the daemon straight away. SMAppService -- the newer API -- instead needs
# the person to find the app in Login Items and switch it on, which is a second
# step in another application for something they have already agreed to. Both
# routes are kept: this is the one that is tried.
#
# SMJobBless requires the helper to carry its own Info.plist and launchd job
# inside the binary, and each side to name a code requirement the other must
# satisfy. macOS checks both before it installs anything.
TEAM_ID="$(printf '%s' "$SIGN_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
# A real identity always carries its team in brackets. Given one that does not
# -- a hash, a name typed by hand -- the requirements below would name an empty
# team, nothing could ever satisfy them, and the app would quietly install its
# helper the other way instead. Ad-hoc signing has no team by definition and is
# allowed to carry on: that build cannot bless anything and says so at the point
# it tries.
if [ -z "$TEAM_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "error: no team identifier in the signing identity '$SIGN_ID'." >&2
  echo "       The helper's code requirements are built from it, so a build" >&2
  echo "       without one installs a daemon nothing is allowed to talk to." >&2
  echo "       Use the full name, as security find-identity prints it." >&2
  exit 1
fi
HELPER_LABEL="$BUNDLE_ID.helper"
APP_REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
HELPER_REQUIREMENT="anchor apple generic and identifier \"$HELPER_LABEL\" and certificate leaf[subject.OU] = \"$TEAM_ID\""

HELPER_PLISTS="$(mktemp -d)"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__HELPER_NAME__|$HELPER_NAME|" \
  -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" \
  -e "s|__APP_REQUIREMENT__|$APP_REQUIREMENT|" \
  "$HERE/resources/helper-info.plist" > "$HELPER_PLISTS/info.plist"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
  "$HERE/resources/helper-launchd.plist" > "$HELPER_PLISTS/launchd.plist"

swift build -c release --product LukottaHelper \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$HELPER_PLISTS/info.plist" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist \
  -Xlinker "$HELPER_PLISTS/launchd.plist"

# Where SMJobBless looks for it. The copy in Contents/MacOS goes on being what
# SMAppService runs, so a Mac that took that route keeps working.
mkdir -p "$CONTENTS/Library/LaunchServices" "$CONTENTS/Library/LaunchDaemons"
HELPER_BUILT="$(swift build -c release --product LukottaHelper --show-bin-path)/LukottaHelper"
cp "$HELPER_BUILT" "$CONTENTS/MacOS/$HELPER_NAME"
cp "$HELPER_BUILT" "$CONTENTS/Library/LaunchServices/$HELPER_LABEL"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__HELPER_NAME__|$HELPER_NAME|" \
  "$HERE/resources/helper.plist" \
  > "$CONTENTS/Library/LaunchDaemons/$BUNDLE_ID.helper.plist"
rm -rf "$HELPER_PLISTS"

# Sparkle ships as a framework and must be embedded and signed inside the
# bundle. Its XCFramework is resolved by SwiftPM; take the built slice.
SPARKLE="$(find "$HERE/.build/artifacts" -name Sparkle.framework -path "*macos-arm64*" -print -quit 2>/dev/null)"
if [ -n "$SPARKLE" ]; then
  mkdir -p "$CONTENTS/Frameworks"
  /usr/bin/ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
  printf 'Embedded Sparkle\n'
fi

# Sparkle in the languages it does not ship.
#
# It carries 35 localisations; this application has 37. macOS resolves a
# localisation per bundle, so the framework falling back to English is not
# something the app's own tables can answer for -- a reader with the whole
# interface in Estonian was still asked about updates in English.
#
# This has to write inside the framework, which is only safe because the
# re-signing below runs after it.
if [ -d "$CONTENTS/Frameworks/Sparkle.framework" ] && [ -d "$HERE/translations/sparkle" ]; then
  /usr/bin/python3 "$HERE/scripts/sparkle-strings.py" \
    "$CONTENTS/Frameworks/Sparkle.framework" "$HERE/translations/sparkle" || {
      echo "error: Sparkle's own strings would not build" >&2; exit 1; }
fi

# The Sparkle public key is generated once with scripts/sparkle-keys.sh and set
# in the environment (or a local file). Without it the app still builds and
# runs; it simply cannot verify an update, so it must not pretend it can.
SPARKLE_KEY="${LUKOTTA_SPARKLE_PUBLIC_KEY:-$(cat "$HERE/.sparkle-public-key" 2>/dev/null || true)}"
sed -e "s|__HELPER_REQUIREMENT__|$HELPER_REQUIREMENT|" \
  -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s|__SPARKLE_PUBLIC_KEY__|${SPARKLE_KEY}|" \
    -e "s|__APP_NAME__|$APP_NAME|" -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
    -e "s|__MIN_MACOS__|$MIN_MACOS|" -e "s|__FEED_URL__|$FEED_URL|" \
    -e "s|__ICON_SET__|$ICON_SET|" -e "s|__MARK_SET__|$MARK_SET|" \
    -e "s|__SWITCH_SET__|$SWITCH_SET|" \
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
  --platform macosx --minimum-deployment-target "$MIN_MACOS" \
  --app-icon "$ICON_SET" --output-partial-info-plist /dev/null >/dev/null
[ -f "$CONTENTS/Resources/Assets.car" ] || { echo "error: actool produced no Assets.car" >&2; exit 1; }
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

# What this copy of the app is made of, part by part.
#
# The app is not one program: it carries an engine, a Linux image, the crates
# the engine reads disk formats with, and our own patches to two of them. Each
# moves on its own schedule and each has already gone out of step with what was
# installed on somebody's Mac without anything noticing. The versions are stated
# here, once, from the lock the build is pinned to -- so a part added to the
# lock appears here without anybody remembering to add it.
/usr/bin/python3 - "$HERE" "$CONTENTS/Resources/components.json" <<'PARTS'
import json, os, sys
here, out = sys.argv[1], sys.argv[2]
lock = json.load(open(os.path.join(here, "vendor/engine.lock")))
parts = {}
for name, held in lock.items():
    if name.startswith("_") or not isinstance(held, dict):
        continue
    stated = held.get("version") or held.get("oci_digest")
    if stated:
        parts[name] = stated
# Our own changes to the engine and its crates. An app built without
# scripts/build-engine.sh runs the upstream binaries and says so here rather
# than claiming fixes it does not have.
patches = os.path.join(here, "vendor/engine/anylinuxfs/PATCHES")
if os.path.exists(patches):
    parts["engine_patches"] = " ".join(sorted(open(patches).read().split()))
else:
    parts["engine_patches"] = "none"
json.dump(parts, open(out, "w"), indent=2, sort_keys=True)
print(f"  {len(parts)} parts recorded")
PARTS

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

# The update watcher is a bare Mach-O and is signed in its own right, under a
# name of its own. codesign otherwise takes a bare Mach-O's identifier from its
# file name, and "update-check" is not an identifier anybody should see.
if [ -f "$CONTENTS/MacOS/update-check" ]; then
  /usr/bin/codesign --force --options runtime \
    --identifier "$BUNDLE_ID.update-check" \
    --sign "$SIGN_ID" "$CONTENTS/MacOS/update-check" >/dev/null 2>&1 \
    || { echo "error: could not sign the update watcher" >&2; exit 1; }
fi

# The helper is a separate executable and must be signed in its own right --
# and, for the copy SMJobBless installs, under the identifier the app's
# requirement names. codesign takes the identifier of a bare Mach-O from its
# file name, which for that copy is already the label.
if [ -f "$CONTENTS/MacOS/$HELPER_NAME" ]; then
  # Not tolerated. An unsigned helper is refused by the system at the moment
  # somebody tries to set it up, which is on their Mac rather than here.
  /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" \
    "$CONTENTS/MacOS/$HELPER_NAME" >/dev/null 2>&1 \
    || { echo "error: could not sign the helper in Contents/MacOS" >&2; exit 1; }
fi
if [ -f "$CONTENTS/Library/LaunchServices/$HELPER_LABEL" ]; then
  /usr/bin/codesign --force --options runtime --identifier "$HELPER_LABEL" \
    --sign "$SIGN_ID" "$CONTENTS/Library/LaunchServices/$HELPER_LABEL" >/dev/null 2>&1 \
    || { echo "error: could not sign the privileged helper" >&2; exit 1; }
fi

# The entitlements are given here, not to a binary inside: the app's executable
# is the bundle's, so signing the bundle is what signs it. Handed to a nested
# Mach-O -- which is what this used to do -- they would be signed onto a file
# the app no longer runs, and the hypervisor would be refused to the process
# that needs it.
printf 'Signing with: %s\n' "$SIGN_ID"
/usr/bin/codesign --force --options runtime \
  --entitlements "$HERE/lukotta.entitlements" \
  --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 \
  || /usr/bin/codesign --force --entitlements "$HERE/lukotta.entitlements" \
    --sign "$SIGN_ID" "$OUT" >/dev/null
/usr/bin/codesign --verify --strict "$OUT" && printf 'Signature verified\n'

# What the helper will actually admit. It admits a caller by code requirement,
# and the requirement names the bundle identifier; a process that does not
# satisfy it is refused everything the helper does -- unlocking a physical
# drive without a password panel, reading a first sector to tell BitLocker from
# NTFS, making room for a fourth drive -- and nothing says why except a line in
# the helper's log. Loosening the requirement instead would weaken the one
# check standing between any process on the Mac and a root daemon.
/usr/bin/codesign --verify -R "=identifier \"$BUNDLE_ID\"" \
  "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || {
  echo "error: $APP_NAME does not satisfy identifier \"$BUNDLE_ID\"," >&2
  echo "       so the privileged helper would refuse it." >&2
  exit 1
}
printf 'The app satisfies the helper'"'"'s requirement\n'

# How to prove to Apple who is submitting. notarytool takes credentials three
# ways and this takes whichever is there, since which one a machine has depends
# on how it was set up rather than on anything about this project:
#
#   a keychain profile        LUKOTTA_NOTARY_PROFILE, or "lukotta" if a profile
#                             of that name exists
#   an App Store Connect key  LUKOTTA_NOTARY_KEY, _KEY_ID and _ISSUER
#   an Apple ID               LUKOTTA_APPLE_ID, _APP_PASSWORD and _TEAM_ID
#
# Naming any of them turns notarisation on. A build that names none is signed
# and not notarised, which is enough to run on the machine that built it.
# Xcode's notarytool where there is one, rather than whatever xcrun resolves.
# The Command Line Tools copy cannot read every kind of stored credential, and
# reports one that works as missing.
NOTARYTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool"
[ -x "$NOTARYTOOL" ] || NOTARYTOOL="$(/usr/bin/xcrun -f notarytool 2>/dev/null || echo notarytool)"

NOTARY_ARGS=""
NOTARY_HOW=""
# Named, or not at all. Discovering a stored profile and using it meant every
# build during an afternoon's work was submitted to Apple and waited on, for a
# binary that never left the machine. scripts/release.sh names the profile, so
# a release still notarises; nothing else has to.
PROFILE="${LUKOTTA_NOTARY_PROFILE:-}"
if [ -n "$PROFILE" ]; then
  NOTARY_ARGS="--keychain-profile $PROFILE"
  NOTARY_HOW="the keychain profile \"$PROFILE\""
elif [ -n "${LUKOTTA_NOTARY_KEY:-}" ] && [ -n "${LUKOTTA_NOTARY_KEY_ID:-}" ] \
  && [ -n "${LUKOTTA_NOTARY_ISSUER:-}" ]; then
  NOTARY_ARGS="--key $LUKOTTA_NOTARY_KEY --key-id $LUKOTTA_NOTARY_KEY_ID --issuer $LUKOTTA_NOTARY_ISSUER"
  NOTARY_HOW="an App Store Connect key"
elif [ -n "${LUKOTTA_APPLE_ID:-}" ] && [ -n "${LUKOTTA_APP_PASSWORD:-}" ] \
  && [ -n "${LUKOTTA_TEAM_ID:-}" ]; then
  NOTARY_ARGS="--apple-id $LUKOTTA_APPLE_ID --password $LUKOTTA_APP_PASSWORD --team-id $LUKOTTA_TEAM_ID"
  NOTARY_HOW="the Apple ID $LUKOTTA_APPLE_ID"
fi

if [ -n "$NOTARY_ARGS" ] && [ "$SIGN_ID" != "-" ]; then
  printf 'Notarising with %s…\n' "$NOTARY_HOW"
  ZIP="$(dirname "$OUT")/$APP_NAME-notarise.zip"
  rm -f "$ZIP"
  # ditto keeps the signature intact; zip(1) does not.
  /usr/bin/ditto -c -k --keepParent "$OUT" "$ZIP"
  # Unquoted on purpose: these are several arguments, not one.
  # shellcheck disable=SC2086
  if "$NOTARYTOOL" submit "$ZIP" $NOTARY_ARGS --wait; then
    # Stapling puts the ticket inside the bundle, so a first launch works
    # without asking Apple — which matters on a machine that is offline.
    /usr/bin/xcrun stapler staple "$OUT"
    /usr/sbin/spctl -a -vv -t install "$OUT" 2>&1 | sed 's/^/  /'
  else
    # The commonest cause is a locked screen: the credential lives in the Local
    # Items keychain, which locks with the session, and reads then exactly like
    # a credential that was never stored.
    printf 'error: notarisation failed; the build is signed but not notarised\n' >&2
    printf '  If it said no keychain item was found: the screen is probably\n' >&2
    printf '  locked. The credential is in the Local Items keychain, which\n' >&2
    printf '  locks with the session and then reads exactly like a credential\n' >&2
    printf '  that was never stored. Unlock the Mac and run this again.\n' >&2
    printf '  ./scripts/notary-status.sh tells the two apart.\n' >&2
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
