#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
V="$HERE/helpers/validate-key.sh"
VALID="110011-220022-330033-440044-550055-660066-700007-711711"
UNDASHED="110011220022330033440044550055660066700007711711"

# --- numerical recovery password: normalized to canonical dashed form --------
out="$($V "$VALID")"
[ "$out" = "$VALID" ] || { echo "FAIL: dashed valid key"; exit 1; }
out="$($V "$UNDASHED")"
[ "$out" = "$VALID" ] || { echo "FAIL: undashed normalization"; exit 1; }
out="$($V "110011 220022 330033 440044 550055 660066 700007 711711")"
[ "$out" = "$VALID" ] || { echo "FAIL: spaced normalization"; exit 1; }

# --- recovery-shaped input is validated strictly ----------------------------
if "$V" "110011-220022-330033-440044-550055-660066-700007-711712" >/dev/null 2>&1; then
  echo "FAIL: bad checksum accepted"; exit 1
fi
if "$V" "999999-220022-330033-440044-550055-660066-700007-711711" >/dev/null 2>&1; then
  echo "FAIL: out-of-range block accepted"; exit 1
fi
if "$V" "110011-220022-330033-440044-550055-660066-700007-71171" >/dev/null 2>&1; then
  echo "FAIL: 47-digit recovery key accepted"; exit 1
fi
err="$("$V" "110011-220022-330033-440044-550055-660066-700007-71171" 2>&1 || true)"
printf '%s' "$err" | grep -F '47 digits' >/dev/null || { echo "FAIL: wrong-length error does not state the actual digit count"; exit 1; }
err="$("$V" "110011-220022-330033-440044-550055-660066-700007-711712" 2>&1 || true)"
printf '%s' "$err" | grep -F 'Group 8' >/dev/null || { echo "FAIL: checksum error does not identify the bad group"; exit 1; }

# --- user passwords pass through verbatim -----------------------------------
for pw in 'Correct Horse Battery!' '12000008' 'p@ss-word 42' 'ÜmlautPass'; do
  out="$($V "$pw")"
  [ "$out" = "$pw" ] || { echo "FAIL: password not passed through verbatim: $pw"; exit 1; }
done

# A password that happens to be alphanumeric with hyphens is not a recovery key.
out="$($V "110011-220022-330033-440044-550055-660066-700007-AAAAAA")"
[ "$out" = "110011-220022-330033-440044-550055-660066-700007-AAAAAA" ] || {
  echo "FAIL: non-numeric input should be treated as a password"; exit 1; }

# --- empty input is rejected with an actionable message ---------------------
if "$V" "" >/dev/null 2>&1; then echo "FAIL: empty credential accepted"; exit 1; fi
err="$("$V" "" 2>&1 || true)"
printf '%s' "$err" | grep -F 'recovery key' >/dev/null || { echo "FAIL: empty-input error is not actionable"; exit 1; }

echo "PASS: BitLocker password / recovery-key validator"
