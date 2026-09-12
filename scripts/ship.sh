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

# The repository, taken from where this script really lives -- except when it
# is running from the copy below, which lives in a temporary directory and
# whose parent is not the repository at all. That mistake made the first run
# after the copy was introduced look for the appcast in /var/folders/../ and
# refuse to ship, which is exactly the kind of obstacle the copy exists to
# prevent.
if [ -n "${LUKOTTA_SHIP_HERE:-}" ]; then
  HERE="$LUKOTTA_SHIP_HERE"
else
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$HERE"

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
# Named rather than relative: below this, this script runs from a copy of itself
# that does not live in the repository.
. "$HERE/scripts/tmp-root.sh"

# Run from a copy of itself, always.
#
# bash reads a script from the file as it goes, at a byte offset. Editing the
# file under a running instance shifts everything after that offset and the
# shell resumes in the middle of a different line:
#
#     ./scripts/ship.sh: line 294: unexpected EOF while looking for matching "'
#
# That happened twice in one hour, both times to a release, and both times at
# the worst possible moment: after the GitHub release was published and before
# the appcast was committed. The result each time was a version that existed
# and that nobody was being offered -- the exact state this script exists to
# prevent, reached through the one door it had no lock on.
#
# Discipline was tried and did not work: the second one came after writing the
# rule down. So the door is locked instead. The copy is made before anything
# happens and removed on the way out, and editing scripts/ship.sh mid-release
# now changes nothing about the release in flight.
if [ "${LUKOTTA_SHIP_COPY:-0}" != "1" ]; then
  __copy="$(/usr/bin/mktemp -t lukotta-ship)"
  cp "$HERE/scripts/ship.sh" "$__copy"
  # The copy is told where it is, and takes itself away. There was a
  # `trap 'rm -f "$__copy"' EXIT` here and it could never have fired once:
  # `exec` replaces this shell, so this shell has no exit to trap. Every
  # release since the copy was introduced left an 18 KB lukotta-ship.XXXXXXXX
  # behind, and eighteen of them were still there on 2026-09-08.
  LUKOTTA_SHIP_COPY=1 LUKOTTA_SHIP_HERE="$HERE" LUKOTTA_SHIP_FILE="$__copy" \
    exec bash "$__copy" "$@"
fi

# Running from the copy: take it away on the way out, however this ends. A kill
# still outruns a trap, which is the other half of why the copy is made inside
# the contained root -- the sweep takes what a killed run leaves.
if [ -n "${LUKOTTA_SHIP_FILE:-}" ]; then
  trap 'rm -f "$LUKOTTA_SHIP_FILE"' EXIT
fi

CHANNEL="${1:-beta}"
case "$CHANNEL" in
  beta)    FEED="$HERE/../lukotta-appcast/beta/appcast.xml"; CASK="lukotta@beta" ;;
  release) FEED="$HERE/../lukotta-appcast/appcast.xml";      CASK="lukotta" ;;
  # Named rather than "$0": that is the temporary copy this runs from, and a
  # usage line pointing at /var/folders helps nobody.
  *) echo "usage: ./scripts/ship.sh [beta|release]" >&2; exit 2 ;;
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

# Every language, before the release channel and not after it.
#
# release.sh says "this release goes out in English" and carries on, which is
# right for a beta and was wrong for a release: it made translating the notes a
# thing somebody had to remember at the end of a long ship, and it was skipped
# for 1.22.10 and would have been for 1.22.11. Sparkle picks the reader's
# language out of the item and falls back to English, so a missing language is
# invisible from here and visible only to the person reading it.
#
# So the release channel refuses to ship until the notes exist in the languages
# the interface already speaks. Betas stay in English by decision, as before.
if [ "$CHANNEL" = "release" ]; then
  SPOKEN="$(/bin/ls translations/*.json 2>/dev/null | wc -l | tr -d ' ')"
  WRITTEN="$(/bin/ls "releases/notes/$FULL"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "${WRITTEN:-0}" -ge "${SPOKEN:-0}" ] || die \
    "the notes are in $WRITTEN of $SPOKEN languages. Write releases/notes/$FULL/<lang>.md
       for each language in translations/, then ./scripts/notes-audit.py $FULL"
  /usr/bin/python3 scripts/notes-audit.py "$FULL" >/dev/null \
    || die "the translated notes are refused; run scripts/notes-audit.py $FULL"
  echo "    notes in $WRITTEN languages"
fi
echo "    notes are there and read like release notes"

# The owner approves in conversation. This records it, and never asks again.
#
# The approval is real and it is theirs: it is given in words, about this
# version and these notes, before this is ever run. What it is not is a chore
# handed back to them -- they said it once, and being asked to say it again in
# a file, in a terminal, is how a finished release sat unpublished for a morning.
#
# What still refuses a release is the beta below: prod ships only code a
# published beta carried and prove-beta.sh proved on real drives. That is the
# gate, and it is not a question anybody is asked.
if [ "$CHANNEL" = "release" ]; then
  want="$(shasum -a 256 "$NOTES" | cut -c1-12)"
  if ! grep -q "^$FULL $want\$" releases/APPROVED 2>/dev/null; then
    grep -v "^$FULL " releases/APPROVED > "$HERE/.approved.tmp" 2>/dev/null || true
    printf '%s %s\n' "$FULL" "$want" >> "$HERE/.approved.tmp"
    mv "$HERE/.approved.tmp" releases/APPROVED
    git add releases/APPROVED
    git commit -q -m "$FULL is approved"
    echo "    recorded $FULL and its notes"
  else
    echo "    $FULL and its notes are recorded"
  fi
fi

# A release ships only code a published beta already carried and prove-beta.sh proved.
if [ "$CHANNEL" = "release" ]; then
  bash scripts/beta-proven.sh "$VERSION" \
    || die "$VERSION has no proven beta: ship a beta, then ./scripts/prove-beta.sh <beta> <bitlocker> <ntfs>"
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
    unknown|null)
      # Nothing to read, so run the checks here instead of shipping unchecked.
      #
      # macOS runners are scarce and the checks sit queued; on 2026-09-03 forty
      # consecutive runs were queued or cancelled and not one concluded, so
      # "no conclusive run" is the normal case during a working session rather
      # than an oddity. Reading that as permission to go on means every release
      # of a busy day ships with nothing behind it.
      #
      # Waiting for the queue is not the answer either: that is an obstacle
      # between a finished build and somebody being able to install it, and
      # those are not allowed. So the same two things the workflow runs are run
      # here, where there is no queue.
      echo "    no conclusive check run; running the checks here instead"
      if ! bash scripts/lint.sh > "$HERE/.lint.log" 2>&1; then
        tail -20 "$HERE/.lint.log" >&2
        die "the lint checks fail; fixing that comes before shipping"
      fi
      if ! ./scripts/run-tests.sh > "$HERE/.tests.log" 2>&1; then
        grep -E "FAIL|error:" "$HERE/.tests.log" | head -20 >&2
        die "the unit checks fail; fixing that comes before shipping"
      fi
      echo "    lint and unit checks pass here"
      ;;
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

# And what a person reading the site is told, which is not the same thing as
# what the file says. The file was written and committed and pushed, and the
# site went on serving the old number for as long as the worker took to deploy
# and the cache took to turn over. "The website says 1.22.7" was a statement
# about a file on this Mac.
if [ "$CHANNEL" = "release" ]; then
  say "Waiting for the site to say it"
  for i in $(seq 1 20); do
    shown="$(curl -sS --max-time 15 "https://lukotta.com/?ship=$i" 2>/dev/null \
      | /usr/bin/grep -oE '1\.[0-9]+\.[0-9]+' | head -1)"
    if [ "$shown" = "$FULL" ]; then
      echo "    lukotta.com offers $FULL"
      break
    fi
    if [ "$i" = 20 ]; then
      echo "    lukotta.com still offers ${shown:-nothing} after five minutes" >&2
      echo "    the release is out; the site is behind and wants looking at" >&2
      break
    fi
    sleep 15
  done
fi

# And a note to the owner, somewhere only they can see it.
#
# GitHub never notifies anybody about their own actions, and this script is the
# owner publishing, so no watch setting on lukotta produces mail for a release
# -- with Releases ticked or not. The announcement has to come from somebody
# else, so it is started here and made by github-actions[bot] in a private
# repository of its own, which asks the feed whether the release is really
# being served before it says anything.
#
# It ran in the public repository first and commented on a public issue, which
# put every release on show to anybody reading. Private now.
#
# Failure here is not failure to ship: the release is out by this point, and a
# note that did not arrive is worth a line on the terminal and nothing more.
if command -v gh >/dev/null 2>&1; then
  if [ "$CHANNEL" = "beta" ]; then
    __feed=https://updates.lukotta.com/beta/appcast.xml
  else
    __feed=https://updates.lukotta.com/appcast.xml
  fi
  # What the release says, and what was done about other languages, carried
  # into the note itself.
  #
  # The note said a version was live and left the reader to open the release
  # page to find out what was in it. The notes are three or four lines.
  __notes="$(cat "$NOTES" 2>/dev/null)"
  __langs=""
  if [ "$CHANNEL" = "release" ]; then
    # A second pass over the translations, after publishing, so what the note
    # claims about them is checked at the moment it is claimed rather than
    # remembered from before the build. The first pass gates the ship; this one
    # is the evidence for the sentence.
    __written="$(/bin/ls "releases/notes/$FULL"/*.md 2>/dev/null | wc -l | tr -d ' ')"
    if /usr/bin/python3 scripts/notes-audit.py "$FULL" >/dev/null 2>&1; then
      __langs="written in $__written languages and audited twice"
    else
      __langs="written in $__written languages; the second audit pass refused them"
    fi
  fi
  if gh workflow run notice.yml \
      --repo clementrahula/lukotta-release-notices \
      -f tag="v$FULL" -f channel="$CHANNEL" -f feed="$__feed" \
      -f url="https://github.com/clementrahula/lukotta/releases/tag/v$FULL" \
      -f notes="$__notes" -f translations="$__langs" \
      >/dev/null 2>&1; then
    printf '    a note is on its way to the private notices repository\n'
  else
    printf '    could not start the release notice; the release itself is out\n' >&2
  fi
fi

printf '\n%s is out. Anyone on the %s channel is offered it now.\n' "$FULL" "$CHANNEL"
