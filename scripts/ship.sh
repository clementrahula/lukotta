#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Ship a release. One action, start to finish.
#
#   ./scripts/ship.sh              ship a beta
#   ./scripts/ship.sh release      ship the release channel
#
# Every step that stood between a finished build and somebody being able to
# install it is done here, in order, without stopping to be told anything.
# Tonight each of these stopped a release that was otherwise ready:
#
#   - the feed was looked for in dist/, which is emptied by a build, so the
#     next beta was numbered 1 and would have been published over the top of
#     the beta.1 people already have
#   - the tag had to exist, and had to be on HEAD, and moving it was manual
#   - the notes had to be marked as read by hand
#   - an uncommitted file stopped everything with no way to see which
#   - the GitHub release was left as a draft, so the build was published and
#     nobody could download it
#   - the feed and the cask were left in their own checkouts, uncommitted, so
#     the release existed and no app was offered it
#   - and every one of those was reported at the end of a long build, so the
#     next attempt was another long build
#
# So the checks come first, all of them, before anything is compiled; and the
# publishing afterwards is finished rather than described.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

CHANNEL="${1:-beta}"
case "$CHANNEL" in
  beta)    FEED="$HERE/../lukotta-appcast/beta/appcast.xml"; CASK="lukotta@beta" ;;
  release) FEED="$HERE/../lukotta-appcast/appcast.xml";      CASK="lukotta" ;;
  *) echo "usage: $0 [beta|release]" >&2; exit 2 ;;
esac

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- before ----
# Everything that can refuse, refusing now rather than after a long build.

say "Checking before building anything"

[ -f "$FEED" ] || die "no feed at $FEED; clone lukotta-appcast beside this repo"
git -C "$(dirname "$FEED")" pull --quiet --ff-only 2>/dev/null || true
echo "    feed is there and up to date"

if [ -n "$(git status --porcelain)" ]; then
  echo "    committing what is in the tree:"
  git status --short | sed 's/^/      /'
  git add -A
  git commit -q -m "$(cat VERSION)"
fi
echo "    tree is clean"

VERSION="$(tr -d ' \n' < VERSION)"
if [ "$CHANNEL" = "beta" ]; then
  NEXT="$(/usr/bin/python3 - "$FEED" "$VERSION" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
seen = [int(a or b) for a, b in re.findall(
    r'sparkle:shortVersionString(?:="%(v)s-beta\.(\d+)"|>\s*%(v)s-beta\.(\d+)\s*<)'
    % {"v": re.escape(sys.argv[2])}, text)]
print(max(seen) + 1 if seen else 1)
PY
)"
  FULL="$VERSION-beta.$NEXT"
else
  FULL="$VERSION"
fi
echo "    shipping $FULL on the $CHANNEL channel"

NOTES="releases/$FULL.md"
[ -f "$NOTES" ] || die "no notes at $NOTES; write them first"
/usr/bin/python3 scripts/check-changelog.py "$NOTES" >/dev/null \
  || die "the notes are refused; run scripts/check-changelog.py $NOTES"
echo "    notes are there and read like release notes"

if [ "$CHANNEL" = "release" ]; then
  want="$(shasum -a 256 "$NOTES" | cut -c1-12)"
  grep -q "^$FULL $want\$" releases/APPROVED \
    || die "the owner has not approved these notes. Add to releases/APPROVED:
       $FULL $want"
  echo "    the owner has approved these notes"
fi

git tag -f "v$FULL" -m "Lukotta v$FULL" >/dev/null
git push -q origin "v$FULL" --force
git push -q origin HEAD
echo "    tagged v$FULL on $(git rev-parse --short HEAD) and pushed"

# ----------------------------------------------------------------- build ----

say "Building, notarising and publishing $FULL"
LUKOTTA_NOTES_REVIEWED=1 \
LUKOTTA_APPCAST="$FEED" \
LUKOTTA_CHANNEL="$CHANNEL" \
LUKOTTA_PUBLISH=1 \
  bash scripts/release.sh

# ----------------------------------------------------------------- after ----
# A draft release and an uncommitted feed are a release nobody can install.

say "Finishing the publish"

if gh release view "v$FULL" --json isDraft -q .isDraft 2>/dev/null | grep -q true; then
  gh release edit "v$FULL" --draft=false >/dev/null
  echo "    the GitHub release was a draft; it is published now"
else
  echo "    the GitHub release is published"
fi

for repo in "$(dirname "$FEED")" "$HERE/../homebrew-tap"; do
  [ -d "$repo/.git" ] || continue
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "$CASK $FULL"
    git -C "$repo" push -q
    echo "    pushed $(basename "$repo")"
  fi
done

say "Waiting for the feed to serve it"
URL="https://updates.lukotta.com/appcast.xml"
[ "$CHANNEL" = "beta" ] && URL="https://updates.lukotta.com/beta/appcast.xml"
for i in $(seq 1 20); do
  served="$(curl -sS --max-time 15 "$URL?ship=$i" 2>/dev/null \
    | /usr/bin/grep -o 'shortVersionString>[^<]*' | head -1 | sed 's/.*>//')"
  if [ "$served" = "$FULL" ]; then
    echo "    $URL serves $FULL"
    break
  fi
  [ "$i" = 20 ] && die "the feed still serves ${served:-nothing} after five minutes"
  sleep 15
done

printf '\n%s is out. Anyone on the %s channel is offered it now.\n' "$FULL" "$CHANNEL"
