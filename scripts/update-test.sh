#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Prove that an update works before anybody receives one.
#
# An update is the only thing this app does that cannot be undone by trying
# again: it replaces the running application, and a version that will not start
# takes the working one with it. It is also the flow least likely to be tried,
# because trying it by hand means cutting a release first.
#
# So it is cut here, against the beta channel, and applied for real: two builds
# of this tree, a signed archive, an appcast served over HTTP from this Mac, and
# Sparkle's own updater doing the download, the signature check, the swap and
# the relaunch. Nothing is simulated.
#
# Four things are checked, in the order somebody meets them:
#
#   1. a fresh install, on a Mac that has never had this app or anylinuxfs;
#   2. an update applied over it, with the settings and the Linux environment
#      as they were;
#   3. what the update left behind -- the helper, the guest, the passphrases;
#   4. rollback, when the new version will not start at all.
#
# Beta only. It never touches the released app, its helper, its settings or its
# saved passphrases.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

APP_NAME="Lukotta Beta"
BUNDLE_ID="com.lukotta.beta"
INSTALLED="/Applications/$APP_NAME.app"
BINARY="$INSTALLED/Contents/MacOS/$APP_NAME"
WORK="${LUKOTTA_UPDATE_WORK:-$(mktemp -d)}"
PORT="${LUKOTTA_UPDATE_PORT:-8973}"
FEED="http://127.0.0.1:$PORT/appcast.xml"
SIGN="$(find "$HERE/.build" -name sign_update -type f -perm -111 -print -quit 2>/dev/null || true)"
[ -n "$SIGN" ] || { echo "error: sign_update not found; run swift build" >&2; exit 1; }

VERSION="$(tr -d ' \n' < VERSION)"
FROM_BUILD="${LUKOTTA_UPDATE_FROM:-900000}"
TO_BUILD="$((FROM_BUILD + 1))"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }
# Runs the condition itself, so there is no $? left over from something else to
# be read by mistake.
that() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
file_exists() { [ -f "$1" ]; }
same() { [ "$1" = "$2" ]; }
installed_build() {
  /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INSTALLED/Contents/Info.plist" 2>/dev/null
}

server=""
clean_up() {
  if [ -n "$server" ]; then
    kill "$server" 2>/dev/null || true
    # Waited for, so the shell does not report the signal it was just sent as
    # though something had gone wrong at the end of a run that passed.
    wait "$server" 2>/dev/null || true
  fi
  [ -z "${LUKOTTA_UPDATE_WORK:-}" ] && rm -rf "$WORK" || true
}
trap clean_up EXIT

printf '==> Building the version to update from (build %s)\n' "$FROM_BUILD"
LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$FROM_BUILD" ./build-app.sh "$HERE/dist/$APP_NAME.app" >/dev/null

printf '\na Mac that has never had this app\n'
# Everything this app could have left on a Mac, taken away: its settings, its
# Linux environment, its record of what was open. The helper stays registered --
# unregistering it needs an authorisation panel, and a fresh install onto a Mac
# that has one is the ordinary case anyway.
# This app's own directory, which since the engine was given one is the only
# place it keeps anything. ~/.anylinuxfs belongs to whatever else on this Mac
# uses the same engine, and wiping it here would be this harness doing the exact
# thing the app was changed to stop doing.
ENGINE_HOME="$HOME/Library/Application Support/$APP_NAME/engine"
SETTINGS_BACKUP="$WORK/settings.plist"
defaults export "$BUNDLE_ID" "$SETTINGS_BACKUP" >/dev/null 2>&1 || true
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$ENGINE_HOME/.anylinuxfs/alpine" "$ENGINE_HOME/.anylinuxfs/alpine.unpacking"
if "$BINARY" --smoke-test >"$WORK/first-run.log" 2>&1; then
  ok "it starts on a Mac with nothing of its own on it"
else
  bad "it starts on a Mac with nothing of its own on it"
  sed 's/^/    /' "$WORK/first-run.log"
fi
FIXTURE="${LUKOTTA_UPDATE_FIXTURE:-$HOME/.lukotta-testvols/crowd/drive1.img}"
if [ -f "$FIXTURE" ]; then
  if "$BINARY" --e2e container="$FIXTURE" passphrase=unused plain="$FIXTURE" \
      >"$WORK/first-mount.log" 2>&1 || grep -q "it mounts" "$WORK/first-mount.log"; then
    ok "it opens a drive with no Linux environment on the Mac to start from"
  else
    bad "it opens a drive with no Linux environment on the Mac to start from"
    tail -5 "$WORK/first-mount.log" | sed 's/^/    /'
  fi
  that "and the environment it unpacked states its version" \
    file_exists "$ENGINE_HOME/.anylinuxfs/alpine/rootfs.ver"
else
  printf '  ..   no fixture at %s; the first mount is not tried\n' "$FIXTURE"
fi

# Something to lose: settings written by this version, which the update must
# leave exactly as they are.
defaults write "$BUNDLE_ID" lukottaUpdateProbe -string "written-before-the-update"
BEFORE_PROBE="$(defaults read "$BUNDLE_ID" lukottaUpdateProbe 2>/dev/null || echo "")"

printf '\nan update, applied the way a person receives one\n'
printf '  building the version to update to (build %s)\n' "$TO_BUILD"
LUKOTTA_INSTALL=0 LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$TO_BUILD" \
  ./build-app.sh "$WORK/$APP_NAME.app" >/dev/null

mkdir -p "$WORK/feed"
ZIP="$WORK/feed/$APP_NAME-$VERSION-$TO_BUILD.zip"
/usr/bin/ditto -c -k --keepParent "$WORK/$APP_NAME.app" "$ZIP"
SIG_LINE="$("$SIGN" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$ZIP")"
SIGNATURE="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
that "the archive is signed with the release key" test -n "$SIGNATURE" -a -n "$LENGTH"

python3 "$HERE/scripts/appcast.py" \
  --appcast "$WORK/feed/appcast.xml" \
  --version "$VERSION" \
  --build "$TO_BUILD" \
  --url "http://127.0.0.1:$PORT/$(basename "$ZIP")" \
  --length "$LENGTH" \
  --signature "$SIGNATURE" \
  --min-system "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INSTALLED/Contents/Info.plist")" \
  --pubdate "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" >/dev/null
that "and described in an appcast" test -s "$WORK/feed/appcast.xml"

( cd "$WORK/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
server=$!
for _ in $(seq 1 20); do
  /usr/bin/curl -fsS "$FEED" >/dev/null 2>&1 && break
  /bin/sleep 0.25
done
that "the feed answers" /usr/bin/curl -fsS -o /dev/null "$FEED"

that "the installed app is the one to update from" same "$(installed_build)" "$FROM_BUILD"

set +e
"$BINARY" --update-test "$FEED" >"$WORK/update.log" 2>&1
status=$?
set -e
sed 's/^/    /' "$WORK/update.log"
that "Sparkle downloaded, checked, installed and relaunched it" same "$status" "0"

for _ in $(seq 1 40); do
  [ "$(installed_build)" = "$TO_BUILD" ] && break
  /bin/sleep 0.5
done
that "and the app in /Applications is the new build" same "$(installed_build)" "$TO_BUILD"

printf '\nwhat the update was not allowed to disturb\n'
that "the settings written before it are still there" \
  same "$(defaults read "$BUNDLE_ID" lukottaUpdateProbe 2>/dev/null || echo "")" "$BEFORE_PROBE"
that "the Linux environment is still unpacked" \
  file_exists "$ENGINE_HOME/.anylinuxfs/alpine/rootfs.ver"
that "the new copy carries its own helper" \
  test -n "$(find "$INSTALLED/Contents/Library/LaunchDaemons" -type f -print -quit 2>/dev/null)"
# And the copy the newer route installs, signed under the label it is blessed
# as -- a bundle missing that installs nothing at all, and says so nowhere.
that "and the copy that gets installed with a password" \
  test -x "$INSTALLED/Contents/Library/LaunchServices/$BUNDLE_ID.helper"
BLESSED_ID="$(/usr/bin/codesign -d -v "$INSTALLED/Contents/Library/LaunchServices/$BUNDLE_ID.helper" 2>&1 \
  | sed -n 's/^Identifier=//p')"
that "which is signed as the daemon the app is allowed to install" \
  same "$BLESSED_ID" "$BUNDLE_ID.helper"
# The helper composes the mach service, the client requirement and its own
# removal paths from the app's identifier. It reads that from the Info.plist
# embedded in itself, so the suffix has to come off -- or it listens somewhere
# nobody calls and refuses the one app allowed to call it.
that "and the app it will answer to is this one, not itself" \
  test "$(/usr/bin/strings "$INSTALLED/Contents/Library/LaunchServices/$BUNDLE_ID.helper" \
    | grep -c "$BUNDLE_ID.helper.helper")" = "0"
if "$BINARY" --smoke-test >"$WORK/after-update.log" 2>&1; then
  ok "and the updated app starts"
else
  bad "and the updated app starts"
fi

printf '\na version that will not start at all\n'
# Rollback keeps the outgoing bundle aside and puts it back after three launches
# that never reach a working window. Proved with a binary that cannot run rather
# than by describing it.
SUPPORT="$HOME/Library/Application Support/$APP_NAME"
KEPT="$SUPPORT/previous"
rm -rf "$KEPT"
mkdir -p "$KEPT"
/usr/bin/ditto "$INSTALLED" "$KEPT/$APP_NAME.app"
that "the working version is kept aside before the swap" test -d "$KEPT/$APP_NAME.app"

# Not a version that starts and fails -- the app puts that back itself. This is
# one whose own code never runs: the binary inside the bundle is replaced with
# something the system will not load, which is what a bad build, a broken
# download or a signature the loader rejects looks like from the outside.
BROKEN="$WORK/broken"
rm -rf "$BROKEN"; mkdir -p "$BROKEN"
/usr/bin/ditto "$INSTALLED" "$BROKEN/$APP_NAME.app"
printf 'not a Mach-O\n' > "$BROKEN/$APP_NAME.app/Contents/MacOS/$APP_NAME-app"
/usr/bin/ditto "$BROKEN/$APP_NAME.app" "$INSTALLED"
rm -f "$SUPPORT/launch-attempts"

that "the broken version really cannot start" \
  test -z "$("$BINARY" --smoke-test 2>/dev/null | head -1)"

# Opened again and again, the way somebody would: click, nothing, click.
for _ in 1 2 3; do "$BINARY" --smoke-test >/dev/null 2>&1 || true; done
if "$BINARY" --smoke-test 2>/dev/null | grep -q started; then
  ok "opened a few times, it puts the working version back and starts"
else
  bad "opened a few times, it puts the working version back and starts"
  # Never leave this Mac worse than it was found.
  /usr/bin/ditto "$KEPT/$APP_NAME.app" "$INSTALLED"
fi
that "and the app in /Applications is the one that worked" \
  same "$(installed_build)" "$TO_BUILD"
rm -rf "$KEPT" "$SUPPORT/launch-attempts"

printf '\n==> Putting this Mac back\n'
# The harness installs a build numbered far above any real one, so a beta left
# like that answers "up to date" to every genuine feed until somebody notices.
LUKOTTA_BRANDING=beta ./build-app.sh "$HERE/dist/$APP_NAME.app" >/dev/null 2>&1 \
  && printf '  the real beta is installed again\n' \
  || printf '  could not rebuild the beta; run ./build-app.sh yourself\n'
defaults delete "$BUNDLE_ID" lukottaUpdateProbe >/dev/null 2>&1 || true
if [ -f "$SETTINGS_BACKUP" ]; then
  defaults import "$BUNDLE_ID" "$SETTINGS_BACKUP" >/dev/null 2>&1 \
    && printf '  and the settings it had before\n'
fi

printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
[ "$fail" = "0" ]
