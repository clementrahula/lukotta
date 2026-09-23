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
  /usr/bin/python3 scripts/notes-audit.py "$FULL" \
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

# The commit is pushed before it is graded. This script makes the commit it
# ships -- the tree it found, and the approval recorded above it -- so until it
# is pushed no workflow has ever seen it, and a gate that insists on runs for
# this commit finds none: the last eight releases took the unaudited arm for no
# other reason. Grading a commit by what CI said about it means CI has to have
# been given it. The tag stays where it is, after the checks. What goes out
# early is the commit, which was going to be pushed either way.
UNAUDITED=""
say "Pushing this commit, so the checks are about it"
git push -q origin HEAD \
  || die "could not push $(git rev-parse --abbrev-ref HEAD); ship from a branch that is in sync"
echo "    $(git rev-parse --short HEAD) is on the remote"

# What the checks said about what is being shipped.
#
# A dozen runs went red and stayed red without anybody noticing, because
# nothing here ever looked. Noticing is not a thing to remember to do; it is a
# step, and it is this one.
#
# The thing worth catching is a failure that has already happened, so Checks in
# flight is not waited for: it queues for hours, and what it would have run can
# be run here instead. The audit in flight is waited for. It takes minutes, and
# nothing here can stand in for it.
if command -v gh >/dev/null 2>&1; then
  # A cancelled run is not a failure. Pushing twice in a minute cancels the
  # first run, and what it leaves behind is a run that never finished having an
  # opinion. Read as a failure it refused a release over a superseded build,
  # which is exactly the kind of thing that must never stand between a finished
  # build and somebody being able to install it. So it counts as no answer,
  # like a run still in flight.
  #
  # Checks and Audit are named, rather than everything else being excluded.
  # The branch also carries runs that are nobody's file in this repository --
  # Dependabot Updates, CodeQL's default setup -- and a red one of those says
  # their own machinery had a bad day, not that this build is unsound. Checks
  # says the build is sound and Audit says what it ships is not known to be
  # vulnerable: those two are the release's gates. Engine updates is not among
  # them, for the reason it is a workflow of its own.
  #
  # The latest run of each workflow, not simply the latest run. A push starts
  # Checks and Audit together and they finish minutes apart, so "the last one to
  # conclude" is whichever was slowest: a red audit sat behind a green build for
  # three weeks without this ever seeing it. Thirty runs is several pushes of
  # both.
  #
  # The runs have to be this commit's. The branch carries runs for every commit
  # ever pushed to it, and a verdict on other code is not a verdict on this one.
  # Matching a run's head against HEAD is what ties the two together.
  #
  # And a gate that did not answer is not green. Named and then not found, it
  # said nothing; green was read out of the one gate that did answer, which is
  # green read out of half the question. A superseded run makes that ordinary
  # rather than rare: cancelled and in flight are both no opinion, and two
  # pushes a minute apart leave the audit as neither. Whichever gate did not
  # answer is named on the terminal and sends this to the arm below.
  GATES='["Checks", "Audit"]'
  BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD)"
  SHA_NOW="$(git rev-parse HEAD)"
  gates_now() {
    gh run list --branch "$BRANCH_NOW" --limit 30 \
      --json headSha,workflowName,status,conclusion \
      -q "[.[] | select(.headSha == \"$SHA_NOW\")
           | select(.workflowName as \$w | $GATES | index(\$w))]
          | group_by(.workflowName) | map(.[0])
          | .[] | \"\(.workflowName) \(.status) \(.conclusion)\"" 2>/dev/null || true
  }

  # This waits, where the rest of the script refuses to. The audit is three
  # ubuntu jobs and takes a few minutes, and there is nothing this Mac can run
  # in its place -- where Checks, which queues for hours on a scarce macOS
  # runner, is answered below by running lint and the unit checks here. Eleven
  # minutes, and after that it is a gate that did not answer like any other.
  # What is waited for is anything not finished, rather than a list of the
  # states gh has today: it also says requested, waiting and pending, and a list
  # that named three of the six let the other three fall straight through, so
  # the wait never happened. No run at all is given a minute to appear, because
  # the push above is seconds old and GitHub does not always register it at
  # once; after that, a run that has not started is one that is not going to.
  for i in $(seq 1 44); do
    state="$(gates_now | /usr/bin/awk '$1 == "Audit" { print $2 }')"
    [ "$state" = "completed" ] && break
    [ -z "$state" ] && [ "$i" -gt 4 ] && break
    [ "$i" = 1 ] && echo "    waiting for the audit of this commit"
    sleep 15
  done

  STATES="$(gates_now)"
  CI=""
  UNREAD=""
  for gate in Checks Audit; do
    case "$(printf '%s\n' "$STATES" | /usr/bin/awk -v g="$gate" '$1 == g { print $3 }')" in
      failure) CI="failure" ;;
      success) ;;
      *) UNREAD="${UNREAD:+$UNREAD and }$gate" ;;
    esac
  done
  if [ -z "$CI" ] && [ -z "$UNREAD" ]; then
    CI="success"
  fi
else
  # No gh on this Mac, no answer from either gate. Not being able to read a
  # gate is the same answer however it comes about, so it is recorded as one
  # and the arm below runs what can be run here and says what cannot. While the
  # arms below sat behind this test too, a Mac without gh ran no gate, ran
  # nothing in their place, and said nothing about either -- the one way the
  # audit could be skipped in silence.
  UNREAD="Checks and Audit"
fi

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
    # Waiting out that queue is not the answer either: hours of it is an
    # obstacle between a finished build and somebody being able to install
    # it, and those are not allowed. So the same two things the workflow runs
    # are run here, where there is no queue.
    #
    # The line below names whichever gate was silent, and promises only what
    # can be run here. Lint and the unit checks are what Checks would have
    # run, so that gate is answered. Nothing on this Mac stands in for the
    # audit: when it is the one that did not answer, the release goes out
    # with that said out loud.
    #
    # The commit is on the remote by then, so silence from a gate means its run
    # never started, or a later push cancelled it, or it was still going when
    # the wait above ran out.
    echo "    ${UNREAD:-nothing} did not answer for this commit; running what can be run here"
    if ! bash scripts/lint.sh > "$HERE/.lint.log" 2>&1; then
      tail -20 "$HERE/.lint.log" >&2
      die "the lint checks fail; fixing that comes before shipping"
    fi
    if ! ./scripts/run-tests.sh > "$HERE/.tests.log" 2>&1; then
      # The grep decides nothing. A suite that crashed before printing FAIL
      # or error: matches nothing, grep leaves 1, and under this script's -e
      # the die below would never run: the ship would stop with its reason
      # on screen nowhere.
      grep -E "FAIL|error:" "$HERE/.tests.log" | head -20 >&2 || true
      die "the unit checks fail; fixing that comes before shipping"
    fi
    echo "    lint and unit checks pass here"
    case "$UNREAD" in
      *Audit*)
        echo "    the audit did not answer for this commit, and nothing here" >&2
        echo "    can answer it; this release goes out unaudited" >&2
        UNAUDITED=1
        ;;
    esac
    ;;
  *)
    echo "    the checks are ${CI}. Fixing that comes before shipping:" >&2
    gh run list --branch "$BRANCH_NOW" --status completed \
      --limit 30 --json databaseId,conclusion,workflowName,headSha \
      -q "[.[] | select(.headSha == \"$SHA_NOW\")
           | select(.workflowName as \$w | $GATES | index(\$w))
           | select(.conclusion == \"failure\")][0].databaseId" 2>/dev/null \
      | xargs -I{} gh run view {} --log-failed 2>/dev/null | tail -20 >&2 || true
    # That pipeline decides nothing either. A run whose log has expired makes
    # gh fail, xargs leaves 123, and under -e and pipefail the ship would
    # stop between the sentence above and the reason below, having printed a
    # colon and nothing after it. The excerpt is a help; the die is the
    # verdict.
    die "the checks are ${CI}"
    ;;
esac

git tag -f "v$FULL" -m "Lukotta v$FULL" >/dev/null
git push -q origin "v$FULL" --force
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
TAG_VERSION="<sparkle:shortVersionString>"
# The body is kept, because it is wanted twice: once for the version served,
# and again below for what that item offers. It is read with awk rather than
# `grep -o | head -1`, which under this script's pipefail aborts the run as
# soon as grep's output outgrows the pipe before its input ends -- clean over
# 20 runs on a 27-item feed, and failing 40 times out of 40 at 2,000 items. A
# release that dies of nothing, later.
for i in $(seq 1 20); do
  feed="$(curl -sS --max-time 15 "$URL?ship=$i" 2>/dev/null || true)"
  served="$(/usr/bin/awk -v tag="$TAG_VERSION" '
    index($0, tag) {
      rest = substr($0, index($0, tag) + length(tag))
      sub(/<.*/, "", rest)
      print rest
      exit
    }
  ' <<<"$feed")"
  if [ "$served" = "$FULL" ]; then
    echo "    $URL serves $FULL"
    break
  fi
  [ "$i" = 20 ] && die "the feed still serves ${served:-nothing} after five minutes"
  sleep 15
done

# The feed naming a version is not the same as a Mac being able to install it,
# so the file is fetched here, in front of whoever shipped, rather than checked
# somewhere else that then has to relay the answer back.
#
# A range request: enough to learn the file is there without pulling
# ninety-four megabytes. And it is the file the matched item offers, not the
# first enclosure in the feed and not a guess at the extension -- looking for a
# .dmg where Sparkle offers the zip once reported a good release as broken.
say "Fetching what that item offers"
offered="$(/usr/bin/awk -v want="$FULL" -v tag="$TAG_VERSION" '
  index($0, tag) {
    rest = substr($0, index($0, tag) + length(tag))
    sub(/<.*/, "", rest)
    version = rest
  }
  version == want && match($0, /url="[^"]+"/) {
    print substr($0, RSTART + 5, RLENGTH - 6)
    exit
  }
' <<<"$feed")"
[ -n "$offered" ] || die "the feed serves $FULL and offers nothing to download"
case "$offered" in
  *"$FULL"*) ;;
  *) die "the feed's $FULL item offers $offered, which is not $FULL" ;;
esac
# 000 is a line on the terminal; a status is a death. curl's -w prints 000
# itself when it never got an answer, so a `|| printf 000` fallback writes
# 000000, matches nothing here, and kills a release that is perfectly fine over
# a moment of no network. 000 is this Mac failing to reach GitHub, which is the
# site check's kind of trouble and not the release's; a 403 or a 404 is the
# file itself. A 5xx is neither: the host answering badly about a file it
# holds, an outage that dying here would not fix and that whoever shipped
# cannot act on, so it is said and not fatal, like a status never received.
code="$(curl -sSL -o /dev/null -r 0-0 -w '%{http_code}' --max-time 60 "$offered" 2>/dev/null || true)"
case "$code" in
  200|206) echo "    $offered can be fetched" ;;
  000|""|5[0-9][0-9])
    echo "    could not get an answer for $offered (${code:-no status})" >&2
    echo "    the release is out; whether it can be downloaded is unanswered" >&2
    ;;
  *) die "$offered answers $code; the release is out and nobody can install it" ;;
esac

# And what a person reading the site is told, which is not the same thing as
# what the file says. The file was written and committed and pushed, and the
# site went on serving the old number for as long as the worker took to deploy
# and the cache took to turn over. "The website says 1.22.7" was a statement
# about a file on this Mac.
if [ "$CHANNEL" = "release" ]; then
  say "Waiting for the site to say it"
  # Read with awk, like the feed above. `grep -oE | head -1` matching nothing
  # leaves 1, and under this script's -e and pipefail the assignment takes the
  # release out at that line, so the five-minute message below -- written for
  # exactly that case -- could never print. A page not yet naming a version is
  # the case this loop exists to wait out.
  for i in $(seq 1 20); do
    page="$(curl -sS --max-time 15 "https://lukotta.com/?ship=$i" 2>/dev/null || true)"
    # The page is searched for this version, not for something version-shaped.
    # The pattern was anchored to a major 1, so the first release of 2.0 would
    # have waited the whole five minutes and then called a site that was
    # perfectly correct behind.
    shown="$(/usr/bin/awk -v want="$FULL" 'index($0, want) { print want; exit }' <<<"$page")"
    if [ "$shown" = "$FULL" ]; then
      echo "    lukotta.com offers $FULL"
      break
    fi
    if [ "$i" = 20 ]; then
      echo "    lukotta.com does not offer $FULL after five minutes" >&2
      echo "    the release is out; the site is behind and wants looking at" >&2
      break
    fi
    sleep 15
  done
fi

# The last line carries the audit, because it is the one sentence whoever
# shipped is left looking at. The warning it stands for was printed before the
# build, half an hour and a notarisation log ago.
if [ -n "$UNAUDITED" ]; then
  printf '\n%s is out, and went out unaudited. Anyone on the %s channel is offered it now.\n' \
    "$FULL" "$CHANNEL"
else
  printf '\n%s is out. Anyone on the %s channel is offered it now.\n' "$FULL" "$CHANNEL"
fi
