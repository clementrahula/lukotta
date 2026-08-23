#!/bin/bash
# Static checks. Nothing here needs a drive, a network, or Xcode.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
status=0

printf 'swift-format…\n'
# Lowercase, as the directory is and as Package.swift requires. Spelled
# "Sources" this resolved on a case-insensitive volume and linted nothing at
# all on a case-sensitive one, where the whole style gate quietly did nothing.
[ -d "$HERE/sources" ] || { printf 'error: no %s/sources to lint\n' "$HERE" >&2; exit 1; }
if swift format lint --recursive --strict "$HERE/sources" 2>&1 | tee /tmp/lukotta-fmt.log | head -20; then
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
