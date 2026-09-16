#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Everything that can be checked without a drive attached.
set -e

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
swift run --package-path "$HERE" LukottaTests

