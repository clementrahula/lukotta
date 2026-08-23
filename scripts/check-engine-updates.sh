#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Say whether anything the engine is pinned to has moved.
#
#   ./scripts/check-engine-updates.sh
#
# Dependabot watches Package.resolved and the workflows. It cannot see
# vendor/engine.lock, and that is where the parts most likely to carry a fix are
# pinned: the engine itself, the two crates built from source, and the Alpine
# image the guest boots. This checks those.
#
# Exits 0 when everything is current, 1 when something has moved, 2 when it
# could not tell. Nothing is changed: a bump is a decision, and a new engine
# needs Diagnosis.enginesChecked looked at before it is taken.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$HERE/vendor/engine.lock"

field() { /usr/bin/python3 -c "import json;print(json.load(open('$LOCK'))['$1']['$2'])"; }

MOVED=0
UNKNOWN=0

printf 'Pinned in vendor/engine.lock:\n\n'

# anylinuxfs, by its latest release tag.
have="$(field anylinuxfs version)"
if latest="$(/usr/bin/curl -fsSL --max-time 30 \
  https://api.github.com/repos/nohajc/anylinuxfs/releases/latest 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)"; then
  if [ "$have" = "$latest" ]; then
    printf '  anylinuxfs    %-14s current\n' "$have"
  else
    printf '  anylinuxfs    %-14s -> %s\n' "$have" "$latest"
    MOVED=1
  fi
else
  printf '  anylinuxfs    %-14s could not ask GitHub\n' "$have"
  UNKNOWN=1
fi

# The two crates, by their newest version on crates.io.
for crate in imago krun-devices; do
  have="$(field "$crate" version)"
  if latest="$(/usr/bin/curl -fsSL --max-time 30 "https://crates.io/api/v1/crates/$crate" \
    -H 'User-Agent: lukotta-engine-check' 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["crate"]["max_version"])' 2>/dev/null)"; then
    if [ "$have" = "$latest" ]; then
      printf '  %-13s %-14s current\n' "$crate" "$have"
    else
      printf '  %-13s %-14s -> %s\n' "$crate" "$have" "$latest"
      MOVED=1
    fi
  else
    printf '  %-13s %-14s could not ask crates.io\n' "$crate" "$have"
    UNKNOWN=1
  fi
done

# The guest image is pinned by digest, and a digest cannot be compared with a
# version: what matters for it is whether anything in it has an advisory, which
# is what the Trivy job in .github/workflows/audit.yml answers.
printf '  guest image   %s\n' "$(field guest_image oci_digest | cut -c1-19)…"
printf '                checked for advisories by the audit workflow\n'

printf '\n'
if [ "$MOVED" = "1" ]; then
  printf 'Something has moved. Bumping the engine means reading what changed and\n'
  printf 'looking at Diagnosis.enginesChecked, since the rules match on the words\n'
  printf 'the engine prints.\n'
  exit 1
fi
if [ "$UNKNOWN" = "1" ]; then
  printf 'Could not reach one of the sources, so this proves nothing.\n'
  exit 2
fi
printf 'Everything the engine is pinned to is current.\n'
