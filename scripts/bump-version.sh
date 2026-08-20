#!/bin/bash
# Bump the semver in ./VERSION, commit it and tag the release.
#
#   ./scripts/bump-version.sh patch    1.0.0 -> 1.0.1
#   ./scripts/bump-version.sh minor    1.0.1 -> 1.1.0
#   ./scripts/bump-version.sh major    1.1.0 -> 2.0.0
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PART="${1:-patch}"
CUR="$(tr -d ' \n' < "$HERE/VERSION")"
IFS=. read -r MA MI PA <<< "$CUR"
case "$PART" in
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
  *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac
NEW="$MA.$MI.$PA"
[ -z "$(git -C "$HERE" status --porcelain)" ] || {
  echo "error: working tree is dirty; commit first" >&2; exit 1; }
printf '%s\n' "$NEW" > "$HERE/VERSION"
git -C "$HERE" add VERSION
git -C "$HERE" commit -q -m "Release v$NEW"
git -C "$HERE" tag -a "v$NEW" -m "Lukotta v$NEW"
printf 'Bumped %s -> %s and tagged v%s\n' "$CUR" "$NEW" "$NEW"
printf 'Push with: git push origin main --follow-tags\n'
