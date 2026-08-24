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
BUILD="$(git rev-list --count HEAD)"
APP="$HERE/dist/Lukotta.app"
ZIP="$HERE/dist/Lukotta-$VERSION.zip"
REPO="${LUKOTTA_REPO:-clementrahula/lukotta}"
PROFILE="${LUKOTTA_NOTARY_PROFILE:-lukotta}"
# Point this at a checkout of the updates repository to update it in place.
APPCAST="${LUKOTTA_APPCAST:-$HERE/dist/appcast.xml}"
BASE_URL="${LUKOTTA_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$VERSION}"

# A release built from uncommitted work cannot be reproduced from the tag.
[ -z "$(git status --porcelain)" ] || {
  echo "error: working tree is dirty; commit before releasing" >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 || {
  echo "error: no tag v$VERSION; run scripts/bump-version.sh first" >&2; exit 1; }

SIGN_TOOL="$(find "$HERE/.build" -name sign_update -type f -perm -111 -print -quit 2>/dev/null || true)"
[ -n "$SIGN_TOOL" ] || { echo "error: sign_update not found; run swift build" >&2; exit 1; }

printf '==> Building and notarising %s (build %s)\n' "$VERSION" "$BUILD"
rm -rf "$HERE/dist"
# A release is the one build that carries the marks. See TRADEMARKS.txt.
LUKOTTA_BRANDING=official LUKOTTA_NOTARY_PROFILE="$PROFILE" "$HERE/build-app.sh" >/dev/null

# Refuse to ship something Gatekeeper will refuse to open.
spctl -a -vv -t install "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || {
  echo "error: the built app is not notarised" >&2; exit 1; }

printf '==> Checking it starts\n'
# A build that cannot launch is the one failure Sparkle cannot undo: it verifies
# and installs correctly, then the app dies and the old copy is gone. This has
# happened once already, when the Sparkle framework was not embedded and dyld
# refused the binary. Cheaper to find here than on someone else's machine.
SMOKE_LOG="$HERE/dist/smoke.log"
if ! "$APP/Contents/MacOS/Lukotta" --smoke-test >"$SMOKE_LOG" 2>&1; then
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
SOURCES_ZIP="$HERE/dist/Lukotta-$VERSION-source.zip"
"$HERE/scripts/collect-sources.sh" "$SOURCES_DIR" >/dev/null
[ -d "$SOURCES_DIR" ] || { echo "error: no corresponding source was produced" >&2; exit 1; }
rm -f "$SOURCES_ZIP"
/usr/bin/ditto -c -k --keepParent "$SOURCES_DIR" "$SOURCES_ZIP"
printf '    %s (%s)\n' "$(basename "$SOURCES_ZIP")" "$(du -h "$SOURCES_ZIP" | awk '{print $1}')"

printf '==> Release notes\n'
NOTES_DIR="$(dirname "$APPCAST")/notes"
mkdir -p "$NOTES_DIR"
NOTES_FILE="$NOTES_DIR/$VERSION.html"
# This version's own notes, as plain HTML. Each release carries its own file
# under releases/, which is also what GitHub shows on the release page.
python3 - "$VERSION" > "$NOTES_FILE" <<'PYEOF'
import pathlib, re, sys
version = sys.argv[1]
source = pathlib.Path("releases") / f"{version}.md"
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
grep -q "<li>" "$NOTES_FILE" || echo "warning: releases/$VERSION.md is missing or empty" >&2

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
PREVIOUS="${LUKOTTA_PREVIOUS:-$HERE/dist/previous}"
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

    delta="$HERE/dist/Lukotta-$old_build-$BUILD.delta"
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
  --notes-link "${LUKOTTA_NOTES_BASE:-https://updates.lukotta.com}/notes/$VERSION.html" \
  --pubdate "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
  ${DELTA_ARGS[@]+"${DELTA_ARGS[@]}"}

if [ "${LUKOTTA_PUBLISH:-0}" = "1" ]; then
  printf '==> Publishing the GitHub release\n'
  # The deltas go up with the archive in both cases. The appcast points at them
  # on this release, so a first release that skipped them advertised enclosures
  # that answered 404 — Sparkle recovers by downloading the whole archive, but
  # the appcast was wrong and the saving was lost.
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$SOURCES_ZIP" \
      ${DELTA_FILES[@]+"${DELTA_FILES[@]}"} --repo "$REPO" --clobber
  else
    gh release create "v$VERSION" "$ZIP" "$SOURCES_ZIP" \
      ${DELTA_FILES[@]+"${DELTA_FILES[@]}"} --repo "$REPO" \
      --title "Lukotta $VERSION" \
      --notes "Complete corresponding source for the GPL components is attached as Lukotta-$VERSION-source.zip."
  fi
else
  printf '==> Not published. Set LUKOTTA_PUBLISH=1 to create the GitHub release.\n'
fi

printf '\nArchive : %s\n' "$ZIP"
printf 'Appcast : %s\n' "$APPCAST"
printf 'Download: %s/%s\n' "$BASE_URL" "$(basename "$ZIP")"
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
