#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Everything that can be checked without a drive attached.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/scripts/test-key-validator.sh"
swift run --package-path "$HERE" LukottaTests

# Rendering needs a built app: the views live in the application target, and
# nothing else can see them. Skipped rather than failed when there is not one,
# so the tests still run on a fresh clone before anything has been built.
if [ -d "$HERE/dist/Drive Unlocker.app" ]; then
  printf '\nSnapshots…\n'
  "$HERE/scripts/snapshots.sh"
else
  printf '\nSnapshots skipped: no unbranded app in dist/. Run ./build-app.sh first.\n'
fi
