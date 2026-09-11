#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Refuses a release unless its newest beta was proven by prove-beta.sh and nothing but releases/ changed since.
#   ./scripts/beta-proven.sh <version>
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
VERSION="${1:?usage: beta-proven.sh <version>}"
no() { printf 'not proven: %s\n' "$*" >&2; exit 1; }

line="$(grep -E "^$VERSION-beta\.[0-9]+ " releases/BETA-PROVEN 2>/dev/null | sort -V | tail -1)"
[ -n "$line" ] || no "no beta of $VERSION is in releases/BETA-PROVEN; ship a beta and run ./scripts/prove-beta.sh"
read -r BETA COMMIT DIGEST <<<"$line"
LOG="releases/proofs/$BETA.log"
[ -f "$LOG" ] || no "$LOG is missing"
[ "$(shasum -a 256 "$LOG" | cut -c1-12)" = "$DIGEST" ] || no "$LOG is not the log that was recorded"
[ "$(git rev-parse -q --verify "v$BETA^{commit}" 2>/dev/null)" = "$COMMIT" ] \
  || no "tag v$BETA is not the commit that was proven"
git diff --quiet "$COMMIT" HEAD -- . ':(exclude)releases' \
  || no "code changed since $BETA was proven: $(git diff --name-only "$COMMIT" HEAD -- . ':(exclude)releases' | head -3 | paste -sd' ' -)"
grep -q "^FAIL" "$LOG" && no "$LOG records a failure"
grep -qx "VERDICT $BETA: proven" "$LOG" || no "$LOG has no verdict"
for step in published update "bitlocker open" "bitlocker write" "bitlocker delete" "bitlocker reopen" \
  "bitlocker read" "bitlocker speed" "bitlocker eject" "ntfs open" "ntfs write" "ntfs delete" \
  "ntfs reopen" "ntfs read" "ntfs speed" "ntfs eject" keys quit; do
  grep -q "^PASS $step:" "$LOG" || no "$LOG does not show '$step' passing"
done
grep -q "^PASS update: .* -> $BETA " "$LOG" || no "$LOG does not show an update to $BETA"

# Speeds judged here from the raw numbers, not taken on the log's word.
while IFS= read -r s; do
  read -r -a f <<<"$s"
  awk -v w="${f[4]}" -v wb="${f[6]}" -v r="${f[8]}" -v rb="${f[10]}" -v t="${f[12]}" -v tb="${f[14]}" 'BEGIN {
    if (wb != "none" && w < 0.75 * wb) exit 1
    if (rb != "none" && r < 0.75 * rb) exit 1
    if (tb != "none" && t > 1.5 * tb) exit 1 }' || no "a speed regressed: ${s#PASS }"
done < <(grep -E "^PASS (bitlocker|ntfs) speed:" "$LOG")
printf 'proven: %s at %s, and nothing but releases/ changed since\n' "$BETA" "${COMMIT:0:7}"
