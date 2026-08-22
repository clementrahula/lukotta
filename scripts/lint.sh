#!/bin/bash
# Static checks. Nothing here needs a drive, a network, or Xcode.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
status=0

printf 'swift-format…\n'
if swift format lint --recursive --strict "$HERE/Sources" 2>&1 | tee /tmp/lukotta-fmt.log | head -20; then
  [ -s /tmp/lukotta-fmt.log ] && status=1
else
  status=1
fi

printf 'shellcheck…\n'
if command -v shellcheck >/dev/null 2>&1; then
  # SC1091: sourced files are not followed. SC2317: unreachable in trap handlers.
  shellcheck -e SC1091,SC2317 "$HERE"/*.sh "$HERE"/scripts/*.sh || status=1
else
  printf '  shellcheck not installed — brew install shellcheck\n'
fi

printf 'coverage…\n'
"$HERE/scripts/check-coverage.sh" | sed 's/^/  /' || status=1

exit $status
