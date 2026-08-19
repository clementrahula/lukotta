#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
V="$HERE/helpers/validate-key.sh"
VALID="110011-220022-330033-440044-550055-660066-700007-711711"
UNDASHED="110011220022330033440044550055660066700007711711"

out="$($V "$VALID")"
[ "$out" = "$VALID" ] || { echo "FAIL: dashed valid key"; exit 1; }
out="$($V "$UNDASHED")"
[ "$out" = "$VALID" ] || { echo "FAIL: undashed normalization"; exit 1; }
out="$($V "110011 220022 330033 440044 550055 660066 700007 711711")"
[ "$out" = "$VALID" ] || { echo "FAIL: spaced normalization"; exit 1; }

if "$V" "110011-220022-330033-440044-550055-660066-700007-711712" >/dev/null 2>&1; then
  echo "FAIL: bad checksum accepted"; exit 1
fi
if "$V" "1234" >/dev/null 2>&1; then
  echo "FAIL: short key accepted"; exit 1
fi
if "$V" "110011-220022-330033-440044-550055-660066-700007-AAAAAA" >/dev/null 2>&1; then
  echo "FAIL: alphabetic key accepted"; exit 1
fi
if "$V" "999999-220022-330033-440044-550055-660066-700007-711711" >/dev/null 2>&1; then
  echo "FAIL: out-of-range block accepted"; exit 1
fi

echo "PASS: BitLocker recovery-key validator"
