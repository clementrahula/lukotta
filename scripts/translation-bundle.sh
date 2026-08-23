#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Gather everything a translation reviewer needs into one archive.
#
#   ./scripts/translation-bundle.sh [destination.zip]
#
# The archive stands on its own: the languages, the canonical English, the
# context for every string, the screens they appear on, and the words that are
# not free to translate. Nothing in it refers to the source code, so it can be
# read by somebody who has never seen the app.
#
# English is written out here rather than kept in the repository, the catalogue
# already being its home: a second copy is a second thing to drift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HOME/Desktop/lukotta-translations.zip}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/translations"
cp -R "$HERE/translations/." "$STAGE/translations/"
/usr/bin/python3 "$HERE/scripts/english-reference.py" "$STAGE/translations/en.json"

rm -f "$OUT"
cd "$STAGE"
zip -q -r "$OUT" translations -x '*/.*'
printf '  %s\n' "$OUT"
printf '  %s files\n' "$(unzip -l "$OUT" | tail -1 | awk '{print $2}')"
