#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Cut a release: build, notarise, sign the archive, and describe it in the appcast.
#
#   ./scripts/release.sh                 build and prepare everything locally
#   LUKOTTA_PUBLISH=1 ./scripts/release.sh   also create the GitHub release
#
# Nothing here is destructive to a published release: the appcast entry is
# rewritten in place if the same build is released twice, and the GitHub release
# is only created when asked for explicitly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

VERSION="$(tr -d ' \n' < VERSION)"
BUILD="${LUKOTTA_BUILD:-$(git rev-list --count HEAD)}"

# Sparkle offers an update only when its build number is greater than the one
# installed. The commit count is monotonic on a straight line of history and on
# nothing else: a hotfix cut from a shorter branch, a squash merge, or a rewrite
# produces a number that has already been released -- and Sparkle then answers
# "up to date" to everybody, for a release that fixes something, with nothing
# anywhere saying why. Checked against the feed rather than trusted.
highest_published() {
  [ -f "$1" ] || return 0
  /usr/bin/python3 - "$1" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
found = [int(v) for v in re.findall(r'sparkle:version="(\d+)"', text)]
print(max(found) if found else 0)
PY
}
REPO="${LUKOTTA_REPO:-clementrahula/lukotta}"
PROFILE="${LUKOTTA_NOTARY_PROFILE:-lukotta}"

# Which channel this release is for.
#
# The two are the same software and separate everything else: identifier,
# daemon, saved passphrases, feed, and the tag a download hangs off. Keeping
# them apart here is what stops a beta appearing in the released app's feed,
# which is the one mistake this script could make that cannot be taken back --
# people would have it installed before anybody noticed.
case "${LUKOTTA_CHANNEL:-release}" in
  release)
    BRANDING="official"
    APP_NAME="Lukotta"
    TAG="v$VERSION"
    APPCAST_DEFAULT="$HERE/dist/appcast.xml"
    NOTES_BASE_DEFAULT="https://updates.lukotta.com"
    PRERELEASE=()
    ;;
  beta)
    BRANDING="beta"
    APP_NAME="Lukotta Beta"
    TAG="v$VERSION-beta"
    APPCAST_DEFAULT="$HERE/dist/appcast-beta.xml"
    NOTES_BASE_DEFAULT="https://updates-beta.lukotta.com"
    # Marked as such on GitHub, so nobody arrives at it from the front page
    # believing it is the release.
    PRERELEASE=(--prerelease)
    ;;
  *)
    echo "error: LUKOTTA_CHANNEL must be 'release' or 'beta'" >&2; exit 1 ;;
esac
SLUG="$(printf '%s' "$APP_NAME" | tr ' ' '-')"

APP="$HERE/dist/$APP_NAME.app"
ZIP="$HERE/dist/$SLUG-$VERSION.zip"
# The disk image carries no version in its name, and that is deliberate: it is
# what makes
#
#     https://github.com/<repo>/releases/latest/download/Lukotta.dmg
#
# a link that never has to be edited. GitHub resolves /latest/ to the newest
# release that is not a prerelease and then asks for an asset of exactly that
# name, so a versioned one would need the README changed at every release and
# would be wrong in between. The version is not lost: it is the volume name
# Finder shows when the image is opened, and the tag it was published under.
#
# The archive beside it keeps its version, because Sparkle's appcast points at
# one URL per version and they cannot collide.
DMG="$HERE/dist/$SLUG.dmg"
# Point this at a checkout of the updates repository to update it in place.
APPCAST="${LUKOTTA_APPCAST:-$APPCAST_DEFAULT}"
NOTES_BASE="${LUKOTTA_NOTES_BASE:-$NOTES_BASE_DEFAULT}"
BASE_URL="${LUKOTTA_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG}"

# A release built from uncommitted work cannot be reproduced from the tag.
[ -z "$(git status --porcelain)" ] || {
  echo "error: working tree is dirty; commit before releasing" >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 || git rev-parse "v$VERSION" >/dev/null 2>&1 || {
  echo "error: no tag $TAG; run scripts/bump-version.sh first" >&2; exit 1; }

# Against the feed that is actually published, not a copy left in dist by the
# last run on this machine -- which the wipe above has just deleted, and which a
# fresh clone never had, so the check passed by finding nothing.
if [ -z "${LUKOTTA_APPCAST:-}" ]; then
  echo "error: set LUKOTTA_APPCAST to a checkout of the updates repository." >&2
  echo "       Without the published feed there is nothing to check this build" >&2
  echo "       number against, and Sparkle offers an update only when the number" >&2
  echo "       is higher than the one people already have." >&2
  exit 1
fi
PUBLISHED="$(highest_published "$APPCAST")"
if [ -n "$PUBLISHED" ] && [ "$PUBLISHED" != "0" ] && [ "$BUILD" -le "$PUBLISHED" ]; then
  echo "error: this build is $BUILD and $PUBLISHED is already published in" >&2
  echo "       $(basename "$APPCAST"). Sparkle would tell everyone they are up to date." >&2
  echo "       Set LUKOTTA_BUILD to a number above $PUBLISHED, or release from a" >&2
  echo "       branch whose history is longer than the last release's." >&2
  exit 1
fi

# The notes people are shown when the update arrives. Written with the version
# by bump-version.sh and edited since, or drafted here from the commits this
# version is made of -- either way there is a file, and it says what changed in
# this version rather than in whichever one was copied.
#
# The draft is made outside the repository. The check above refused to release
# from a dirty tree, so writing a file into it here would leave the release
# built from something the tag does not have.
NOTES_SOURCE="$HERE/releases/$VERSION.md"
if [ ! -s "$NOTES_SOURCE" ]; then
  printf '==> No releases/%s.md. Drafting from the commits since the last version\n' "$VERSION"
  DRAFT="$(mktemp)"
  "$HERE/scripts/release-notes.py" "$VERSION" > "$DRAFT"
  NOTES_SOURCE="$DRAFT"
  printf '    to keep it: ./scripts/release-notes.py %s --write, and commit it\n' "$VERSION"
fi

# Read before it goes out, by somebody.
#
# Everything else here is automatic and should be: the version, the notes, the
# archive, the signature, the appcast, the deltas. This is the one part a
# machine cannot check, because a line can be true, in order, and still be
# written for the person who made the change rather than the person reading it
# -- and this text is the only thing most people will ever read about the
# release. So it is put on the screen, in full, before anything is built.
printf '\n==> The notes everybody updating will be shown\n\n'
sed 's/^/    /' "$NOTES_SOURCE"
printf '\n'
if [ "${LUKOTTA_NOTES_REVIEWED:-0}" = "1" ]; then
  printf '    Taken as read (LUKOTTA_NOTES_REVIEWED=1).\n\n'
elif [ -t 0 ]; then
  printf '    Read it as somebody updating will: is every line about them, and\n'
  printf '    does it say what changed rather than how it was done?\n\n'
  read -r -p "    Publish these notes? [y/N] " answer
  case "$answer" in
    y | Y | yes | YES) printf '\n' ;;
    *)
      printf '\nNothing was built. Edit releases/%s.md and run this again.\n' "$VERSION"
      exit 1 ;;
  esac
else
  echo "error: nobody can read the notes from here." >&2
  echo "       Run this where somebody is at the keyboard, or set" >&2
  echo "       LUKOTTA_NOTES_REVIEWED=1 having read them elsewhere." >&2
  exit 1
fi

SIGN_TOOL="$(find "$HERE/.build" -name sign_update -type f -perm -111 -print -quit 2>/dev/null || true)"
[ -n "$SIGN_TOOL" ] || { echo "error: sign_update not found; run swift build" >&2; exit 1; }

printf '==> Building and notarising %s (build %s)\n' "$VERSION" "$BUILD"
# The archives previous releases were built from, kept out of the way before the
# wipe. They live in dist/previous by default, and the wipe below deleted them
# every time -- so deltas were silently never built, and every release told
# everybody to download the whole thing.
KEPT_PREVIOUS=""
if [ -d "${LUKOTTA_PREVIOUS:-$HERE/dist/previous}" ]; then
  KEPT_PREVIOUS="$(mktemp -d)/previous"
  /usr/bin/ditto "${LUKOTTA_PREVIOUS:-$HERE/dist/previous}" "$KEPT_PREVIOUS"
fi
rm -rf "$HERE/dist"
# A release is the one build that carries the marks. See TRADEMARKS.txt.
LUKOTTA_BRANDING="$BRANDING" LUKOTTA_NOTARY_PROFILE="$PROFILE" \
  "$HERE/build-app.sh" "$APP" >/dev/null

# Refuse to ship something Gatekeeper will refuse to open.
spctl -a -vv -t install "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || {
  echo "error: the built app is not notarised" >&2; exit 1; }

printf '==> Checking it starts\n'
# A build that cannot launch is the one failure Sparkle cannot undo: it verifies
# and installs correctly, then the app dies and the old copy is gone. This has
# happened once already, when the Sparkle framework was not embedded and dyld
# refused the binary. Cheaper to find here than on someone else's machine.
SMOKE_LOG="$HERE/dist/smoke.log"
if ! "$APP/Contents/MacOS/$APP_NAME" --smoke-test >"$SMOKE_LOG" 2>&1; then
  echo "error: the built app failed to start:" >&2
  sed 's/^/    /' "$SMOKE_LOG" >&2
  exit 1
fi
printf '    starts, and loads every library it needs\n'

printf '==> Archiving\n'
rm -f "$ZIP"
# ditto, not zip: zip(1) does not preserve the signature.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

printf '==> Signing the archive\n'
# Under Lukotta's own key, not the global Sparkle account.
SIG_LINE="$("$SIGN_TOOL" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$ZIP")"
SIGNATURE="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || {
  echo "error: could not read the signature from: $SIG_LINE" >&2; exit 1; }

printf '==> Corresponding source\n'
# GPL-3 section 6(d): source offered from the same place as the binary. A
# release without it is a licence breach, so the release builds it rather than
# leaving it to be remembered.
SOURCES_DIR="$HERE/dist/sources"
SOURCES_ZIP="$HERE/dist/$SLUG-$VERSION-source.zip"
"$HERE/scripts/collect-sources.sh" "$SOURCES_DIR" >/dev/null
[ -d "$SOURCES_DIR" ] || { echo "error: no corresponding source was produced" >&2; exit 1; }
rm -f "$SOURCES_ZIP"
/usr/bin/ditto -c -k --keepParent "$SOURCES_DIR" "$SOURCES_ZIP"
printf '    %s (%s)\n' "$(basename "$SOURCES_ZIP")" "$(du -h "$SOURCES_ZIP" | awk '{print $1}')"

printf '==> Release notes\n'
NOTES_DIR="$(dirname "$APPCAST")/notes"
mkdir -p "$NOTES_DIR"
NOTES_FILE="$NOTES_DIR/$VERSION.html"
# This version's own notes, as plain HTML for Sparkle's panel. The same file
# becomes the body of the GitHub release further down, so the two cannot say
# different things.
python3 - "$VERSION" "$NOTES_SOURCE" > "$NOTES_FILE" <<'PYEOF'
import pathlib, re, sys
version = sys.argv[1]
source = pathlib.Path(sys.argv[2])
body = source.read_text().strip() if source.exists() else ""
items = [re.sub(r"\s+", " ", b).strip() for b in re.split(r"\n(?=- )", body) if b.strip()]
print("<html><body style=\"font: -apple-system-body; margin: 0\">")
print(f"<h2>Version {version}</h2>")
if items:
    print("<ul>")
    for item in items:
        print(f"  <li>{item.lstrip('- ')}</li>")
    print("</ul>")
else:
    print("<p>No notes were written for this version.</p>")
print("</body></html>")
PYEOF
grep -q "<li>" "$NOTES_FILE" || {
  echo "error: $NOTES_SOURCE produced no notes at all, which cannot happen" >&2
  echo "       from a generated file -- it has been edited into something the" >&2
  echo "       reader cannot parse. Every line starts with '- '." >&2
  exit 1
}

# What the release page carries: the same notes, then where the source is. The
# page said only the second of those, so a reader arriving at a release from
# outside the app was told what the licence requires and nothing about the
# version they were looking at.
RELEASE_BODY="$HERE/dist/$SLUG-$VERSION-body.md"
{
  cat "$NOTES_SOURCE"
  printf '\n'
  printf 'Complete corresponding source for the GPL components is attached as %s.\n' \
    "$(basename "$SOURCES_ZIP")"
} > "$RELEASE_BODY"

printf '==> Updates from earlier versions\n'
# Sparkle can send somebody on an earlier build only what changed, which for
# this app is a fraction of ninety megabytes. It needs the earlier build to
# compare against: put the archives of previous releases in dist/previous, or
# point LUKOTTA_PREVIOUS at a directory of them. With none there this does
# nothing, which is what the first release wants.
DELTA_ARGS=()
# The files themselves, so the release uploads exactly the deltas this appcast
# names — rather than globbing dist/, which picks up whatever an earlier run
# left behind and stays a literal "*.delta" when there is nothing there.
DELTA_FILES=()
PREVIOUS="${KEPT_PREVIOUS:-${LUKOTTA_PREVIOUS:-$HERE/dist/previous}}"
DELTA_TOOL="$(find "$HERE/.build" -name BinaryDelta -type f -perm -111 -print -quit 2>/dev/null || true)"
if [ -d "$PREVIOUS" ] && [ -n "$DELTA_TOOL" ]; then
  for archive in "$PREVIOUS"/*.zip; do
    [ -f "$archive" ] || continue
    work="$(mktemp -d)"
    /usr/bin/ditto -x -k "$archive" "$work" 2>/dev/null || { rm -rf "$work"; continue; }
    old_app="$(find "$work" -maxdepth 1 -name "*.app" -print -quit)"
    [ -n "$old_app" ] || { rm -rf "$work"; continue; }
    old_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$old_app/Contents/Info.plist" 2>/dev/null || true)"
    [ -n "$old_build" ] && [ "$old_build" != "$BUILD" ] || { rm -rf "$work"; continue; }

    delta="$HERE/dist/$SLUG-$old_build-$BUILD.delta"
    rm -f "$delta"
    if "$DELTA_TOOL" create "$old_app" "$APP" "$delta" >/dev/null 2>&1; then
      delta_line="$("$SIGN_TOOL" --account "${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}" "$delta")"
      delta_sig="$(printf '%s' "$delta_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
      delta_len="$(printf '%s' "$delta_line" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
      if [ -n "$delta_sig" ] && [ -n "$delta_len" ]; then
        DELTA_ARGS+=(--delta "$old_build:$BASE_URL/$(basename "$delta"):$delta_len:$delta_sig")
        DELTA_FILES+=("$delta")
        printf '    from build %s: %s\n' "$old_build" "$(du -h "$delta" | awk '{print $1}')"
      fi
    else
      printf '    could not build an update from build %s; the whole archive will be sent\n' "$old_build"
    fi
    rm -rf "$work"
  done
fi
[ ${#DELTA_ARGS[@]} -gt 0 ] || printf '    none; everyone downloads the whole archive\n'

printf '==> Building the disk image\n'
# What a person downloads. Sparkle keeps updating from the zip -- that is the
# format it installs -- so a release produces both, and the image is notarised
# and stapled in its own right rather than inheriting it from the app inside:
# Gatekeeper checks the thing that was downloaded, and that is the image.
"$HERE/scripts/make-dmg.sh" "$APP" "$DMG" "$APP_NAME" "$VERSION"
if [ -n "${LUKOTTA_NOTARY_PROFILE:-}" ]; then
  NOTARYTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool"
  [ -x "$NOTARYTOOL" ] || NOTARYTOOL="$(xcrun --find notarytool 2>/dev/null || true)"
  if [ -x "$NOTARYTOOL" ]; then
    if "$NOTARYTOOL" submit "$DMG" --keychain-profile "$PROFILE" --wait >/dev/null; then
      /usr/bin/xcrun stapler staple "$DMG" >/dev/null \
        || { echo "error: the notarisation could not be stapled to the image" >&2; exit 1; }
      printf '    notarised and stapled\n'
    else
      echo "error: the disk image was not notarised" >&2
      exit 1
    fi
  fi
fi
/usr/bin/hdiutil verify "$DMG" >/dev/null 2>&1 \
  || { echo "error: the disk image does not verify" >&2; exit 1; }
printf '    %s\n' "$(du -h "$DMG" | awk '{print $1}')"

printf '==> Describing it in the appcast\n'
mkdir -p "$(dirname "$APPCAST")"
python3 "$HERE/scripts/appcast.py" \
  --appcast "$APPCAST" \
  --version "$VERSION" \
  --build "$BUILD" \
  --url "$BASE_URL/$(basename "$ZIP")" \
  --length "$LENGTH" \
  --signature "$SIGNATURE" \
  --min-system "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")" \
  --notes-link "$NOTES_BASE/notes/$VERSION.html" \
  --pubdate "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
  ${DELTA_ARGS[@]+"${DELTA_ARGS[@]}"}

if [ "${LUKOTTA_PUBLISH:-0}" = "1" ]; then
  printf '==> Publishing the GitHub release\n'
  # The deltas go up with the archive in both cases. The appcast points at them
  # on this release, so a first release that skipped them advertised enclosures
  # that answered 404 — Sparkle recovers by downloading the whole archive, but
  # the appcast was wrong and the saving was lost.
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" "$DMG" "$SOURCES_ZIP" \
      ${DELTA_FILES[@]+"${DELTA_FILES[@]}"} --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes-file "$RELEASE_BODY"
  else
    gh release create "$TAG" "$ZIP" "$DMG" "$SOURCES_ZIP" \
      ${DELTA_FILES[@]+"${DELTA_FILES[@]}"} --repo "$REPO" \
      ${PRERELEASE[@]+"${PRERELEASE[@]}"} \
      --title "$APP_NAME $VERSION" \
      --notes-file "$RELEASE_BODY"
  fi
else
  printf '==> Not published. Set LUKOTTA_PUBLISH=1 to create the GitHub release.\n'
fi

printf '\nArchive : %s\n' "$ZIP"
printf 'Appcast : %s\n' "$APPCAST"
printf 'Update  : %s/%s\n' "$BASE_URL" "$(basename "$ZIP")"
# What the button in the README points at. Worth printing: it is the one URL
# here that is not written down anywhere else, and the first release to carry a
# disk image of this name is the one that makes it start working.
printf 'Download: https://github.com/%s/releases/latest/download/%s\n' \
  "$REPO" "$(basename "$DMG")"
# The feed is served from its own repository — GitHub Pages gives one site one
# custom domain, and the project's website has the other. Point LUKOTTA_APPCAST
# at a checkout of it and the appcast and notes are written straight in, ready
# to commit; without it they land in dist/ and have to be copied across.
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$APP/Contents/Info.plist")"
if [ -d "$(dirname "$APPCAST")/.git" ]; then
  printf '\nCommit and push %s so it is served at\n' "$(dirname "$APPCAST")"
  printf '  %s\n' "$FEED_URL"
else
  printf '\nCopy the appcast and dist/notes into the feed repository\n'
  printf '  git clone https://github.com/clementrahula/lukotta-appcast\n'
  printf '  LUKOTTA_APPCAST=<that checkout>/appcast.xml %s\n' "$0"
  printf 'so they are served at\n'
  printf '  %s\n' "$FEED_URL"
fi
