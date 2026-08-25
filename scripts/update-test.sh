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
signature_holds() { /usr/bin/codesign --verify --deep --strict "$1" >/dev/null 2>&1; }
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
LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$FROM_BUILD" ./build-app.sh "$HERE/dist/$APP_NAME.app" >/dev/null

printf '\na Mac that has never had this app\n'
# Everything this app could have left on a Mac, taken away: its settings, its
# Linux environment, its record of what was open. The helper stays registered --
# unregistering it needs an authorisation panel, and a fresh install onto a Mac
# that has one is the ordinary case anyway.
# This app's own directory, which since the engine was given one is the only
# place it keeps anything. ~/.anylinuxfs belongs to whatever else on this Mac
# uses the same engine, and wiping it here would be this harness doing the exact
# thing the app was changed to stop doing.
# Named after the identifier, as the app names it -- renaming the application
# does not move anybody's Linux environment.
ENGINE_HOME="$HOME/Library/Application Support/$BUNDLE_ID/engine"
# Everything this app keeps is filed under the identifier, including the copy
# of the outgoing version that a rollback puts back -- the app and the shim in
# front of it both name it that way.
SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
KEPT="$SUPPORT/previous"
KEPT_APP="$KEPT/$BUNDLE_ID.app"
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

# What that first mount left. The image stays open until something closes it,
# and an image a machine still has open is one nothing else can open: the
# section further down that holds a drive while an update arrives met "Failed
# to acquire lock on device" and failed four checks for a reason that had
# nothing to do with updates.
for point in "$HOME"/Volumes/*; do
  [ -d "$point" ] || continue
  /sbin/umount -f "$point" >/dev/null 2>&1 || true
  rmdir "$point" >/dev/null 2>&1 || true
done
pkill -f "$INSTALLED/Contents/Resources/engine" >/dev/null 2>&1 || true

# Something to lose: settings written by this version, which the update must
# leave exactly as they are.
defaults write "$BUNDLE_ID" lukottaUpdateProbe -string "written-before-the-update"
BEFORE_PROBE="$(defaults read "$BUNDLE_ID" lukottaUpdateProbe 2>/dev/null || echo "")"

printf '\nan update, applied the way a person receives one\n'
printf '  building the version to update to (build %s)\n' "$TO_BUILD"
LUKOTTA_INSTALL=0 LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$TO_BUILD" \
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

# Kept rather than discarded: which file Sparkle asked for is the only proof
# that a delta was applied as a delta. python3 -m http.server logs to stderr.
SERVER_LOG="$WORK/server.log"
( cd "$WORK/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>"$SERVER_LOG" ) &
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
that "Sparkle downloaded it, checked it, and the app quit for it" same "$status" "0"

# The installer runs on after the app has gone: it waits for the process to
# leave, swaps ninety megabytes of bundle, and only then is the new version
# there. A minute, rather than the twenty seconds this waited before, which was
# most of the time enough.
for _ in $(seq 1 120); do
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
# Before anything starts the new version: a launch that reaches a working app
# drops the copy, which is what disarms the mechanism until the next update
# arms it again. Asked for after three successful launches, as this was, the
# answer is always no and says nothing about whether it was ever made.
that "the outgoing version was kept aside for a rollback" \
  test -x "$KEPT_APP/Contents/MacOS/$APP_NAME"

if "$BINARY" --smoke-test >"$WORK/after-update.log" 2>&1; then
  ok "and the updated app starts"
else
  bad "and the updated app starts"
fi
that "and the copy is dropped once a launch works" \
  test ! -d "$KEPT_APP"

printf '\nan update sent as only what changed\n'
# What almost everybody actually receives. A delta is a patch between two
# bundles rather than a copy of the new one, and it fails differently: it can
# apply cleanly and produce a bundle whose signature no longer matches, or be
# silently ignored so that everybody downloads ninety megabytes instead of two.
# Neither is visible from the outside, so this checks what was fetched and not
# only what ended up installed.
GOOD_BUILD="$TO_BUILD"
DELTA_BUILD="$((TO_BUILD + 1))"
DELTA_TOOL="$(find "$HERE/.build" -name BinaryDelta -type f -perm -111 -print -quit 2>/dev/null || true)"
if [ -z "$DELTA_TOOL" ]; then
  bad "BinaryDelta is built (run swift build)"
else
  printf '  building the version to update to (build %s)\n' "$DELTA_BUILD"
  LUKOTTA_INSTALL=0 LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$DELTA_BUILD" \
    ./build-app.sh "$WORK/next/$APP_NAME.app" >/dev/null

  DELTA_ZIP="$WORK/feed/$APP_NAME-$VERSION-$DELTA_BUILD.zip"
  /usr/bin/ditto -c -k --keepParent "$WORK/next/$APP_NAME.app" "$DELTA_ZIP"
  ZIP_LINE="$("$SIGN" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$DELTA_ZIP")"
  ZIP_SIG="$(printf '%s' "$ZIP_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  ZIP_LEN="$(printf '%s' "$ZIP_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

  # From the copy actually installed, which is what somebody updating has. A
  # delta built against a different copy of the same build applies to nothing.
  DELTA="$WORK/feed/$APP_NAME-$TO_BUILD-$DELTA_BUILD.delta"
  if "$DELTA_TOOL" create "$INSTALLED" "$WORK/next/$APP_NAME.app" "$DELTA" >"$WORK/delta.log" 2>&1; then
    ok "a delta is built between the installed build and the new one"
  else
    bad "a delta is built between the installed build and the new one"
    tail -3 "$WORK/delta.log" | sed 's/^/    /'
  fi
  DELTA_LINE="$("$SIGN" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$DELTA")"
  DELTA_SIG="$(printf '%s' "$DELTA_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  DELTA_LEN="$(printf '%s' "$DELTA_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  that "and signed with the same key as the archive" test -n "$DELTA_SIG" -a -n "$DELTA_LEN"
  # A patch the size of the whole app is a patch that patched nothing.
  if [ -n "$DELTA_LEN" ] && [ -n "$ZIP_LEN" ] && [ "$DELTA_LEN" -lt "$((ZIP_LEN / 2))" ]; then
    ok "and it is a fraction of the archive ($((DELTA_LEN / 1024)) KB against $((ZIP_LEN / 1024 / 1024)) MB)"
  else
    bad "and it is a fraction of the archive ($DELTA_LEN against $ZIP_LEN)"
  fi

  python3 "$HERE/scripts/appcast.py" \
    --appcast "$WORK/feed/appcast.xml" \
    --version "$VERSION" \
    --build "$DELTA_BUILD" \
    --url "http://127.0.0.1:$PORT/$(basename "$DELTA_ZIP")" \
    --length "$ZIP_LEN" \
    --signature "$ZIP_SIG" \
    --delta "$TO_BUILD:http://127.0.0.1:$PORT/$(basename "$DELTA"):$DELTA_LEN:$DELTA_SIG" \
    --min-system "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INSTALLED/Contents/Info.plist")" \
    --pubdate "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" >/dev/null
  that "the appcast offers it to exactly the build installed" \
    grep -q "sparkle:deltaFrom=\"$TO_BUILD\"" "$WORK/feed/appcast.xml"

  # From here on, only what this update asks for.
  : > "$SERVER_LOG"
  set +e
  "$BINARY" --update-test "$FEED" >"$WORK/delta-update.log" 2>&1
  status=$?
  set -e
  sed 's/^/    /' "$WORK/delta-update.log"
  that "Sparkle downloaded it, checked it, and the app quit for it" same "$status" "0"

  that "and what it fetched was the delta" grep -q "\.delta" "$SERVER_LOG"
  if grep -q "$DELTA_BUILD\.zip" "$SERVER_LOG"; then
    bad "and not the whole archive"
    sed 's/^/    /' "$SERVER_LOG"
  else
    ok "and not the whole archive"
  fi

  for _ in $(seq 1 120); do
    [ "$(installed_build)" = "$DELTA_BUILD" ] && break
    /bin/sleep 0.5
  done
  that "the app in /Applications is the patched build" same "$(installed_build)" "$DELTA_BUILD"
  # A delta patches a signed bundle in place, which is where one stops being
  # signed correctly: every file it rewrites has to land byte for byte, or the
  # seal covering it no longer matches. Not spctl -- these builds are signed
  # and not notarised, and Gatekeeper would refuse them for that alone.
  that "and it is still signed as itself" signature_holds "$INSTALLED"
  if "$BINARY" --smoke-test >"$WORK/after-delta.log" 2>&1; then
    ok "and the patched app starts"
  else
    bad "and the patched app starts"
    sed 's/^/    /' "$WORK/after-delta.log"
  fi
  that "the settings survived the patch" \
    same "$(defaults read "$BUNDLE_ID" lukottaUpdateProbe 2>/dev/null || echo "")" "$BEFORE_PROBE"
  that "and the Linux environment with them" \
    file_exists "$ENGINE_HOME/.anylinuxfs/alpine/rootfs.ver"
  GOOD_BUILD="$DELTA_BUILD"
fi

printf '\nan update offered while a drive is open\n'
# The one an update must not do: replace the bundle while the machine serving
# somebody's drive is running out of it. Without the helper that machine is the
# app's own child, so the app puts the update off until the drive is ejected --
# a rule written down in UpdaterRelay and, until now, never once run.
HOLD_BUILD="$((DELTA_BUILD + 1))"
if [ -z "$DELTA_TOOL" ]; then
  HOLD_BUILD="$((TO_BUILD + 1))"
fi
if [ -f "$FIXTURE" ]; then
  printf '  building the version to update to (build %s)\n' "$HOLD_BUILD"
  LUKOTTA_INSTALL=0 LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=beta LUKOTTA_BUILD="$HOLD_BUILD" \
    ./build-app.sh "$WORK/held/$APP_NAME.app" >/dev/null

  HOLD_ZIP="$WORK/feed/$APP_NAME-$VERSION-$HOLD_BUILD.zip"
  /usr/bin/ditto -c -k --keepParent "$WORK/held/$APP_NAME.app" "$HOLD_ZIP"
  HOLD_LINE="$("$SIGN" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$HOLD_ZIP")"
  HOLD_SIG="$(printf '%s' "$HOLD_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  HOLD_LEN="$(printf '%s' "$HOLD_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  python3 "$HERE/scripts/appcast.py" \
    --appcast "$WORK/feed/appcast.xml" \
    --version "$VERSION" \
    --build "$HOLD_BUILD" \
    --url "http://127.0.0.1:$PORT/$(basename "$HOLD_ZIP")" \
    --length "$HOLD_LEN" \
    --signature "$HOLD_SIG" \
    --min-system "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INSTALLED/Contents/Info.plist")" \
    --pubdate "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" >/dev/null

  set +e
  "$BINARY" --update-test "$FEED" hold="$FIXTURE" >"$WORK/held.log" 2>&1
  status=$?
  set -e
  sed 's/^/    /' "$WORK/held.log"
  that "the drive was open when the update arrived" \
    grep -q "holding" "$WORK/held.log"
  that "and the update waited for it rather than pulling it away" \
    grep -q "postponed, because a drive is open" "$WORK/held.log"
  that "then installed once it was ejected" same "$status" "0"
  for _ in $(seq 1 120); do
    [ "$(installed_build)" = "$HOLD_BUILD" ] && break
    /bin/sleep 0.5
  done
  that "and the app in /Applications is the build that waited" \
    same "$(installed_build)" "$HOLD_BUILD"
  that "nothing of the engine is left serving nothing" \
    test -z "$(/usr/sbin/lsof -c anylinuxfs 2>/dev/null | head -1)"
  GOOD_BUILD="$HOLD_BUILD"
else
  printf '  ..   no fixture at %s; an update with a drive open is not tried\n' "$FIXTURE"
fi

printf '\na version that will not start at all\n'
# Rollback keeps the outgoing bundle aside and puts it back after three launches
# that never reach a working window. Proved with a binary that cannot run rather
# than by describing it.
# Named after the identifier, as the app names it.


# Made by the app itself, during the update above, and not by this script.
#
# It used to be copied here before the check, which proved the shim could put
# back a bundle somebody had placed for it -- and nothing at all about whether
# the app keeps one aside when Sparkle replaces it. That is the half that fails
# quietly: a rollback with nothing to roll back to.
if [ -d "$KEPT_APP" ]; then
  ok "the app kept the outgoing version aside when it was replaced"
else
  bad "the app kept the outgoing version aside when it was replaced"
  # The rest of this section needs something to put back, so it is made here --
  # and the check above has already recorded that the app did not.
  mkdir -p "$KEPT"
  /usr/bin/ditto "$INSTALLED" "$KEPT_APP"
fi
that "and it is a working copy, not an empty directory" \
  test -x "$KEPT_APP/Contents/MacOS/$APP_NAME"

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
  /usr/bin/ditto "$KEPT_APP" "$INSTALLED"
fi
that "and the app in /Applications is the one that worked" \
  same "$(installed_build)" "$GOOD_BUILD"
rm -rf "$KEPT" "$SUPPORT/launch-attempts"

printf '\n==> Putting this Mac back\n'
# The harness installs a build numbered far above any real one, so a beta left
# like that answers "up to date" to every genuine feed until somebody notices.
# Without the harnesses: this is the copy left on the Mac afterwards, and a
# pre-release somebody uses is not a place for them.
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
