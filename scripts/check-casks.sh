#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Every cask in the tap points at a download that is really there.
#
#   ./scripts/check-casks.sh [tap directory]
#
# A cask is a version, a URL and a checksum. Nothing in Homebrew notices when
# the release behind that URL goes away: `brew install` fetches it, gets a 404,
# and says the download failed -- which reads as a broken tap rather than as a
# withdrawn version, and is the first thing anybody meets.
#
# It has happened once: the release cask named a version withdrawn before the
# app was made public, and installing the released app answered 404 for as long
# as it took somebody to try it. This is what would have caught that.
#
# Skipped where there is no tap to look at, so a clone without one still lints.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TAP="${1:-${LUKOTTA_TAP:-$HERE/../homebrew-tap}}"

if [ ! -d "$TAP/Casks" ]; then
  printf '  no tap at %s; nothing to check\n' "$TAP"
  exit 0
fi

status=0
found=0
# Whether a URL is there, without fetching what is behind it.
#
# This used to be `curl -sSL -o /dev/null -w '%{http_code}'`, which downloads
# the whole file to check it exists -- ninety-four megabytes for the disk image
# -- with a sixty-second limit. Run while a release was uploading, it ran out
# of time, printed the 200 it already had, and the `|| echo 000` fallback
# appended to it: "answered 200000". A release that was perfectly fine was
# refused, which is the one thing this pipeline must never do.
#
# A range request asks for the first byte. GitHub answers 206, or 200 if it
# ignores the range; either means the file is there.
probe_code() {
  curl -sSL -o /dev/null -r 0-0 -w '%{http_code}' --max-time 60 "$1" 2>/dev/null \
    || printf '000'
}

for cask in "$TAP"/Casks/*.rb; do
  [ -f "$cask" ] || continue
  found=$((found + 1))
  name="$(basename "$cask" .rb)"

  version="$(sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$cask" | head -1)"
  # The URL as written, with #{version} standing where the version goes.
  url="$(sed -n 's/^ *url "\([^"]*\)".*/\1/p' "$cask" | head -1)"
  if [ -z "$version" ] || [ -z "$url" ]; then
    printf '  %s: no version or no url\n' "$name" >&2
    status=1
    continue
  fi
  url="${url//\#\{version\}/$version}"

  code="$(probe_code "$url")"
  if [ "$code" = "200" ] || [ "$code" = "206" ]; then
    printf '  %s %s: the download is there\n' "$name" "$version"
  else
    printf '  %s %s: %s answered %s\n' "$name" "$version" "$url" "$code" >&2
    status=1
  fi
done

[ "$found" -gt 0 ] || printf '  no casks in %s/Casks\n' "$TAP"

# And the link everything else points at.
#
# The README, the website and every "Download" button name
# releases/latest/download/..., which GitHub resolves to the newest release
# that is not a pre-release. That is the right link -- it never names a version
# and never goes stale -- but it answers 404 until a stable release exists, and
# a beta does not count as one. Between making the repository public and
# cutting the first stable release, every download link on the site was dead.
LATEST="https://github.com/${LUKOTTA_REPO:-clementrahula/lukotta}/releases/latest/download/Lukotta.dmg"
code="$(probe_code "$LATEST")"
if [ "$code" = "200" ] || [ "$code" = "206" ]; then
  printf '  the latest stable download is there\n'
else
  printf '  %s answered %s\n' "$LATEST" "$code" >&2
  printf '  Every download link points here. Until a release that is not a\n' >&2
  printf '  pre-release exists, all of them are dead.\n' >&2
  status=1
fi
if [ "$status" -ne 0 ]; then
  printf '\nA cask naming a download that is not there is an install that fails\n' >&2
  printf 'with nothing to say why. Cut the release it names, or take the cask out\n' >&2
  printf 'until there is one.\n' >&2
fi
exit "$status"
