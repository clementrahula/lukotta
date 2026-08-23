#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
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

printf 'nothing private…\n'
# The same check the pre-commit hook runs, over everything git tracks rather
# than over what is staged. A hook can be skipped and a hook can be uninstalled;
# this cannot.
"$HERE/scripts/check-private.py" || status=1

printf 'pinned actions…\n'
# Every action a workflow runs, pinned to a commit. A tag is a name its owner
# can move, and a moved tag runs somebody else's code with this repository's
# token. The version it stands for goes in the comment beside it.
if unpinned=$(grep -nE '^\s*(-\s*)?uses:' "$HERE"/.github/workflows/*.yml \
    | grep -vE 'uses:\s*\S+@[0-9a-f]{40}\b'); then
  printf '  not pinned to a commit:\n%s\n' "$unpinned" | sed 's/^/  /'
  status=1
else
  printf '  all pinned\n'
fi

printf 'coverage…\n'
"$HERE/scripts/check-coverage.sh" | sed 's/^/  /' || status=1

exit $status
