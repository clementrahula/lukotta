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
# publishing afterwards is finished rather than described. Nothing here stops
# to be countersigned: running this is the decision to ship.
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

# The owner approves in conversation. This records it.
#
# The approval is real and it is theirs: it is given in words, about this
# version and these notes, before this is ever run. What it is not is a chore
# handed back to them -- they said it once, and being asked to say it again in
# a file, in a terminal, is how a finished release sat unpublished for an hour.
#
#   ./scripts/ship.sh release --approved
#
# Without the flag the release script refuses, prints the notes and prints the
# line, which is the right answer to "ship this" when nobody has said so.
if [ "$CHANNEL" = "release" ]; then
  case " $* " in
    *" --approved "*)
      want="$(shasum -a 256 "$NOTES" | cut -c1-12)"
      if ! grep -q "^$FULL $want\$" releases/APPROVED 2>/dev/null; then
        grep -v "^$FULL " releases/APPROVED > "$HERE/.approved.tmp" 2>/dev/null || true
        printf '%s %s\n' "$FULL" "$want" >> "$HERE/.approved.tmp"
        mv "$HERE/.approved.tmp" releases/APPROVED
        git add releases/APPROVED
        git commit -q -m "$FULL is approved"
        echo "    recorded the owner's approval of $FULL"
      else
        echo "    $FULL is already approved"
      fi
      ;;
  esac
fi

# What the checks said about what is being shipped.
#
# A dozen runs went red and stayed red without anybody noticing, because
# nothing here ever looked. Noticing is not a thing to remember to do; it is a
# step, and it is this one.
#
# The last completed run on this branch, not a run in flight: a release that
# waits for the checks to finish would wait ten minutes on every ship, and the
# thing worth catching is a failure that has already happened.
if command -v gh >/dev/null 2>&1; then
  # The last run that concluded anything, not the last that stopped. Pushing
  # twice in a minute cancels the first run, and a cancelled run is not a
  # failure -- it is a run that never finished having an opinion. Reading it as
  # one refused a release over a superseded build, which is exactly the kind of
  # thing that must never stand between a finished build and somebody being
  # able to install it.
  CI="$(gh run list --branch "$(git rev-parse --abbrev-ref HEAD)" --status completed \
    --limit 15 --json conclusion \
    -q '[.[].conclusion | select(. == "success" or . == "failure")][0]' 2>/dev/null || true)"
  case "${CI:-unknown}" in
    success) echo "    the checks are green" ;;
    unknown|null) echo "    no conclusive check run to read; going on" ;;
    *)
      echo "    the checks are ${CI}. Fixing that comes before shipping:" >&2
      gh run list --branch "$(git rev-parse --abbrev-ref HEAD)" --status completed \
        --limit 15 --json databaseId,conclusion \
        -q '[.[] | select(.conclusion == "failure")][0].databaseId' 2>/dev/null \
        | xargs -I{} gh run view {} --log-failed 2>/dev/null | tail -20 >&2
      die "the checks are ${CI}"
      ;;
  esac
fi

git tag -f "v$FULL" -m "Lukotta v$FULL" >/dev/null
git push -q origin "v$FULL" --force
git push -q origin HEAD
echo "    tagged v$FULL on $(git rev-parse --short HEAD) and pushed"

# ----------------------------------------------------------------- build ----

say "Building, notarising and publishing $FULL"
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

# The website carries the version in a file of its own, and it was written by
# hand every release until the release it was not: 1.22.0 shipped, and the site
# went on offering 1.21.0 to everybody who read it. A number kept in two places
# is a number that disagrees with itself eventually, so the release writes it.
#
# Only on the release channel. The site describes what people install, and a
# pre-release is not that.
SITE="$HERE/../lukotta-website"
if [ "$CHANNEL" = "release" ] && [ -f "$SITE/site.config.json" ]; then
  git -C "$SITE" pull --quiet --ff-only 2>/dev/null || true
  /usr/bin/python3 - "$SITE/site.config.json" "$FULL" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
config = json.load(open(path, encoding="utf-8"))
config["appVersion"] = version
with open(path, "w", encoding="utf-8") as out:
    json.dump(config, out, indent=2, ensure_ascii=False)
    out.write("\n")
PY
  echo "    the website says $FULL"
fi

# The feed's repository, not the feed's directory. A beta lives one level down
# -- lukotta-appcast/beta/appcast.xml -- so dirname gave a directory with no
# .git in it, the loop skipped it, and 1.22.1-beta.1 was built, notarised,
# published on GitHub and offered to nobody, because the feed describing it
# never left this Mac.
FEED_REPO="$(git -C "$(dirname "$FEED")" rev-parse --show-toplevel 2>/dev/null || true)"

for repo in "$FEED_REPO" "$HERE/../homebrew-tap" "$SITE"; do
  [ -n "$repo" ] && [ -d "$repo/.git" ] || continue
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "$CASK $FULL"
    git -C "$repo" push -q
    echo "    pushed $(basename "$repo")"
  fi
done

# And main, so the code people read on GitHub is the code that was released.
# Everything tonight was on a working branch, so the site, the README and the
# repository front page all described a version that had been superseded.
if [ "$CHANNEL" = "release" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ] && git merge-base --is-ancestor main HEAD 2>/dev/null; then
    git checkout -q main
    git merge --ff-only "$BRANCH" >/dev/null
    git push -q origin main
    git checkout -q "$BRANCH"
    echo "    main fast-forwarded to $BRANCH"
  fi
fi

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
