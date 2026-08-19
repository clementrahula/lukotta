#!/bin/bash
# Validate and normalize a Microsoft BitLocker numerical recovery password.
# Accepts dashes, spaces, or a continuous 48-digit string.
set -u

if [ "$#" -gt 0 ]; then
  RAW="$1"
else
  IFS= read -r RAW || RAW=""
fi

DIGITS="$(printf '%s' "$RAW" | /usr/bin/tr -d '[:space:]-')"
case "$DIGITS" in
  ''|*[!0-9]*)
    echo "BitLocker recovery key must contain only digits, spaces, and hyphens." >&2
    exit 64
    ;;
esac

if [ "${#DIGITS}" -ne 48 ]; then
  echo "BitLocker recovery key must contain exactly 48 digits (8 groups of 6)." >&2
  exit 64
fi

CANON=""
i=0
while [ "$i" -lt 8 ]; do
  start=$((i * 6 + 1))
  end=$((start + 5))
  group="$(printf '%s' "$DIGITS" | /usr/bin/cut -c "${start}-${end}")"
  value=$((10#$group))

  # A genuine numerical recovery-password group is a 16-bit value multiplied
  # by 11. 65535 * 11 = 720885. Divisibility by 11 is the per-block checksum
  # Windows uses to catch mistyped recovery passwords.
  if [ "$value" -gt 720885 ] || [ $((value % 11)) -ne 0 ]; then
    echo "Recovery-key group $((i + 1)) is not a valid BitLocker recovery-password block." >&2
    exit 64
  fi

  if [ -n "$CANON" ]; then
    CANON="$CANON-$group"
  else
    CANON="$group"
  fi
  i=$((i + 1))
done

printf '%s\n' "$CANON"
