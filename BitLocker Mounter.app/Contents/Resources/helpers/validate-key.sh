#!/bin/bash
# Validate and normalize a BitLocker unlock credential.
#
# Two kinds of credential can unlock a BitLocker volume:
#   1. the numerical recovery password  - 48 digits in 8 groups of 6
#   2. the user password the volume was protected with - free-form text
#
# Input that is made up only of digits, spaces and hyphens and carries at least
# RECOVERY_MIN_DIGITS digits is treated as an attempted recovery password and is
# validated strictly, so a mistyped recovery key produces a precise error rather
# than a generic "wrong key" from cryptsetup. Anything else is a user password
# and is passed through verbatim.
set -u

RECOVERY_MIN_DIGITS=20

if [ "$#" -gt 0 ]; then
  RAW="$1"
else
  IFS= read -r RAW || RAW=""
fi

if [ -z "$RAW" ]; then
  echo "Enter the BitLocker password for this drive, or its 48-digit recovery key." >&2
  exit 64
fi

DIGITS="$(printf '%s' "$RAW" | /usr/bin/tr -d '[:space:]-')"

# Does this look like an attempt at a numerical recovery password?
looks_like_recovery=0
case "$DIGITS" in
  ''|*[!0-9]*) ;;
  *) [ "${#DIGITS}" -ge "$RECOVERY_MIN_DIGITS" ] && looks_like_recovery=1 ;;
esac

if [ "$looks_like_recovery" -eq 0 ]; then
  # User password. Pass through exactly as typed - spaces and punctuation are
  # all significant in a BitLocker password.
  printf '%s\n' "$RAW"
  exit 0
fi

if [ "${#DIGITS}" -ne 48 ]; then
  echo "That looks like a recovery key, but it has ${#DIGITS} digits instead of 48 (8 groups of 6). Check for a missing or repeated group." >&2
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
    echo "Group $((i + 1)) of the recovery key ($group) is not valid. Recheck those six digits." >&2
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
