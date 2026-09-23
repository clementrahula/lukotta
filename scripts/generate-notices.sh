#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Brings the guest package table in THIRD_PARTY_NOTICES.md back into agreement
# with vendor/guest-sbom.json. --check reports what differs instead of writing,
# and is what the release gate and the audit workflow run. Both files are in
# the checkout, so this needs no vendor tree, no guest image and no Mac.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
exec /usr/bin/python3 scripts/generate_notices.py \
  THIRD_PARTY_NOTICES.md vendor/guest-sbom.json "$@"
