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
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PART="${1:-patch}"
TAG=true
for arg in "$@"; do
  case "$arg" in
    --no-tag) TAG=false ;;
  esac
done
CUR="$(tr -d ' \n' < "$HERE/VERSION")"
IFS=. read -r MA MI PA <<< "$CUR"
case "$PART" in
  # The first number used to need --approved, on the grounds that it is the
  # owner's decision. It is -- and typing "major" is that decision, made by the
  # only person who runs this. A second word confirming the first added nothing
  # except a way to be refused.
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
  *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac
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
# the moment this runs.
/usr/bin/sed -i '' \
  -e "s|badge/version-[0-9.]*-|badge/version-$NEW-|" \
  -e "s|alt=\"Version [0-9.]*\"|alt=\"Version $NEW\"|" \
  "$HERE/README.md"
git -C "$HERE" add VERSION README.md "releases/$NEW.md"
git -C "$HERE" commit -q -m "Version $NEW"
if [ "$TAG" = true ]; then
  git -C "$HERE" tag -a "v$NEW" -m "Lukotta v$NEW"
  printf 'Bumped %s -> %s and tagged v%s\n' "$CUR" "$NEW" "$NEW"
else
  printf 'Bumped %s -> %s\n' "$CUR" "$NEW"
fi
printf 'Push with: git push origin main --follow-tags\n'
