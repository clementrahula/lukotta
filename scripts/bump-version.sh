#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Bump the semver in ./VERSION and commit it.
#
#   ./scripts/bump-version.sh patch    1.0.0 -> 1.0.1
#   ./scripts/bump-version.sh minor    1.0.1 -> 1.1.0
#   ./scripts/bump-version.sh major    1.1.0 -> 2.0.0   (owner's approval only)
#
# The version is bumped as work lands, not at release time: patch for a fix,
# minor for a feature. Every bump is tagged, so each version is a point in the
# history that can be checked out and built; --no-tag skips that.
#
# The first number is the owner's decision. This refuses to raise it unless
# --approved is given, so that it cannot happen as a side effect.
#
# v1 and v2 are two lines of versions written in one repository, one to a
# branch, and bumping either must leave the other exactly as it is. Which line
# a bump belongs to is read from the branch rather than from the file, so that
# it cannot be got wrong: see LINE below.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PART="${1:-patch}"
TAG=true
APPROVED=false
for arg in "$@"; do
  case "$arg" in
    --no-tag) TAG=false ;;
    --approved) APPROVED=true ;;
  esac
done
CUR="$(tr -d ' \n' < "$HERE/VERSION")"
IFS=. read -r MA MI PA <<< "$CUR"

# Which line of versions this branch carries, and whether it owns the README.
#
# v2 is written on its own branch beside the application people are running.
# Its versions are 2.x and v1's are 1.x, and a bump on either branch must move
# its own line and nothing of the other's. Reading the line from the branch
# rather than from the file is what makes that automatic: on v2 there is no way
# to bump v1's version by accident, and no reason to ask anybody first.
#
# The badge in README.md is v1's. It says which version people can install, and
# on the v2 branch that is still whatever main has released -- so bumping here
# leaves it alone, which is both true and one guaranteed conflict fewer on
# every merge from main.
case "$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')" in
  v2 | v2/*) LINE=2; TOUCH_README=false ;;
  *)         LINE="$MA"; TOUCH_README=true ;;
esac

case "$PART" in
  major | minor | patch) ;;
  *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac
if [ "$MA" -lt "$LINE" ]; then
  # The branch cut from a 1.x main, carrying 1.x in a file that describes 2.x
  # work. Putting it on its own line is not raising the application's version
  # -- v1's is untouched on main -- so it needs no approval and happens
  # whichever part was asked for. It can only happen once.
  MA="$LINE"; MI=0; PA=0
elif [ "$PART" = major ]; then
  [ "$APPROVED" = true ] || {
    echo "error: the first number is the owner's decision. Ask, then pass --approved." >&2
    exit 1; }
  MA=$((MA+1)); MI=0; PA=0
elif [ "$PART" = minor ]; then
  MI=$((MI+1)); PA=0
else
  PA=$((PA+1))
fi
NEW="$MA.$MI.$PA"
[ -z "$(git -C "$HERE" status --porcelain)" ] || {
  echo "error: working tree is dirty; commit first" >&2; exit 1; }
printf '%s\n' "$NEW" > "$HERE/VERSION"
# The notes for this version, drafted from the commits it is made of. Written
# here rather than at release time because a version and its notes are the same
# fact: leave them to be written later and they are forgotten, or the last
# version's file is copied and nobody sees that it was. Edit the file into
# whatever reads best -- it is a starting point, and it is already right about
# what changed.
"$HERE/scripts/release-notes.py" "$NEW" --write
# The README carries the version as a badge, which would otherwise be wrong from
# the moment this runs -- on the line that owns it. See TOUCH_README above.
CHANGED=(VERSION "releases/$NEW.md")
if [ "$TOUCH_README" = true ]; then
  /usr/bin/sed -i '' \
    -e "s|badge/version-[0-9.]*-|badge/version-$NEW-|" \
    -e "s|alt=\"Version [0-9.]*\"|alt=\"Version $NEW\"|" \
    "$HERE/README.md"
  CHANGED+=(README.md)
fi
git -C "$HERE" add "${CHANGED[@]}"
git -C "$HERE" commit -q -m "Version $NEW"
if [ "$TAG" = true ]; then
  git -C "$HERE" tag -a "v$NEW" -m "Lukotta v$NEW"
  printf 'Bumped %s -> %s and tagged v%s\n' "$CUR" "$NEW" "$NEW"
else
  printf 'Bumped %s -> %s\n' "$CUR" "$NEW"
fi
# The branch this was bumped on, not always main: v2 carries its own line of
# versions, and a hint naming the wrong branch is a push to the wrong place.
BRANCH="$(git -C "$HERE" rev-parse --abbrev-ref HEAD)"
printf 'Push with: git push origin %s --follow-tags\n' "$BRANCH"
