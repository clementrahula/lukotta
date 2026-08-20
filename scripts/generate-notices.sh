#!/bin/bash
# Regenerate THIRD_PARTY_NOTICES.md from what is actually shipped.
# Guest package licences come from the Alpine package database inside the image.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="${BLM_SRC_ROOTFS:-$HOME/.anylinuxfs/alpine}/rootfs"
OUT="$HERE/Documentation/THIRD_PARTY_NOTICES.md"
/usr/bin/python3 "$HERE/scripts/generate_notices.py" "$ROOTFS" "$OUT"
printf 'Wrote %s\n' "$OUT"
