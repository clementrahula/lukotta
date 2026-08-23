#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Are the checks keeping up with the app?
#
#   ./scripts/check-coverage.sh
#
# Tests rot by omission rather than by breaking: a screen is added and no
# baseline is recorded for it, a rule is written and nothing exercises it, a
# format is claimed and no end-to-end run opens one. Each of those leaves the
# suite green and the thing untested, and nobody notices for months.
#
# So this looks for the omissions themselves. It is deliberately narrow: every
# rule here is one where the absence can be established, not guessed at.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

FAIL=0
note() { printf '  %s\n' "$1"; }
bad() { printf '  MISSING  %s\n' "$1"; FAIL=1; }

# 1. Every screen has baselines, in both languages and both sizes.
printf 'Screens with baselines…\n'
# From inside scenes() only: the geometries and the appearances are pairs of
# the same shape further down the file.
scenes=$(/usr/bin/python3 -c '
import re
text = open("sources/Lukotta/Snapshots.swift").read()
body = text.split("static func scenes()", 1)[1]
# Only as far as the next function: the geometries and the appearances further
# down the file are pairs of the same shape.
body = re.split(r"\n    (?:@MainActor\n    )?(?:private )?static (?:func|let|var) ", body)[0]
print("\n".join(sorted(set(re.findall(r"\(\s*\n?\s*\"([a-z0-9-]+)\",", body)))))
')
for scene in $scenes; do
  missing=""
  for lang in "" "de-"; do
    for size in ideal min; do
      for mode in light dark; do
        [ -f "tests/snapshots/${lang}${scene}-${size}-${mode}.png" ] || missing="yes"
      done
    done
  done
  [ -n "$missing" ] && bad "no baselines for the \"$scene\" screen"
done
note "$(printf '%s\n' "$scenes" | wc -l | tr -d ' ') screens"

# 2. Every failure rule is exercised. A rule nobody tests is a rule that stops
#    firing when upstream rewords its output, and nothing says so.
printf 'Failure rules with a test…\n'
rules=$(grep -oE 'name: "[a-z0-9-]+", source:' sources/LukottaCore/Diagnosis.swift \
  | sed -E 's/name: "([a-z0-9-]+)".*/\1/' | sort -u)
for rule in $rules; do
  grep -q "\"$rule\"" sources/LukottaTests/main.swift || bad "nothing tests the \"$rule\" rule"
done
note "$(printf '%s\n' "$rules" | wc -l | tr -d ' ') rules"

# 3. Every image format the app claims is opened by the end-to-end run. The
#    claim is in the format table in SPECS.md; the proof is in e2e.sh's
#    fixtures.
#
#    Mentioning the name is not enough — a comment satisfied that, and one
#    format was "covered" for weeks by a line explaining why it was not built.
#    The fixture has to be given a variable, and that variable has to reach the
#    run. Whether the run then opens it is the run's own business: it fails on
#    a fixture that is not there.
printf 'Formats with an end-to-end fixture…\n'
/usr/bin/python3 - <<'PY' || FAIL=1
import re
import sys

FIXTURES = [
    "plain.img", "plain.qcow2", "container.qcow2", "plain.vmdk", "sparse.vmdk",
    "streamed.vmdk", "plain.vhd", "dynamic.vhd", "plain.vdi", "plain.vhdx",
    "exfat.img", "container.img",
]
text = open("scripts/e2e.sh").read()
# The invocation spans several lines now, one fixture to a line. Everything
# from `--e2e` to the first line that does not continue is the hand-over.
run = []
lines = text.splitlines()
for i, line in enumerate(lines):
    if "--e2e" not in line or "$BINARY" not in line:
        continue
    run.append(line)
    while line.rstrip().endswith("\\") and i + 1 < len(lines):
        i += 1
        line = lines[i]
        run.append(line)
    break
missing = []
for fixture in FIXTURES:
    named = re.findall(r'^([A-Z_]+)="[^"]*/' + re.escape(fixture) + '"', text, re.M)
    if not named:
        missing.append(f"the end-to-end run builds no {fixture}")
        continue
    # A variable name must end where it ends: "$VHDX" is a prefix of
    # "$VHDX_DIRTY", so a plain substring test found a fixture that had been
    # taken out of the hand-over.
    if not any(
        re.search(r"\$" + re.escape(name) + r"(?![A-Za-z0-9_])", line)
        for name in named
        for line in run
    ):
        missing.append(f"{fixture} is built and never handed to the run")
for line in missing:
    print(f"  MISSING  {line}")
print(f"  {len(FIXTURES)} formats")
sys.exit(1 if missing else 0)
PY

# 4. Every phase of the interface is drawn by some screen. A phase nobody
#    renders is a screen nobody has looked at since it was written.
printf 'Interface states with a screen…\n'
phases=$(sed -n '/enum Phase {/,/^    }/p' sources/Lukotta/AppModel.swift \
  | grep -oE 'case [a-zA-Z]+' | awk '{print $2}' | sort -u)
for phase in $phases; do
  grep -q "\.$phase" sources/Lukotta/Snapshots.swift || bad "no screen draws the .$phase state"
done
note "$(printf '%s\n' "$phases" | wc -l | tr -d ' ') states"

# 5. Every language has every string. A half-translated release shows English
#    to somebody who chose otherwise.
printf 'Languages fully translated…\n'
/usr/bin/python3 - <<'PY' || FAIL=1
import json, pathlib, sys
catalogue = json.load(open("resources/Localizable.xcstrings"))["strings"]
langs = sorted(p.stem for p in pathlib.Path("translations").glob("*.json"))
short = False
for lang in langs:
    missing = [k for k, e in catalogue.items() if lang not in e.get("localizations", {})]
    if missing:
        print(f"  MISSING  {lang} is short of {len(missing)} strings: {missing[0][:50]}…")
        short = True
print(f"  {len(langs)} languages, {len(catalogue)} strings")
sys.exit(1 if short else 0)
PY

# 6. Every string the code shows is in the catalogue. Check 5 compares the
#    catalogue with the translations, so a string that never reaches the
#    catalogue is invisible to it: untranslatable, shipped in English, and
#    reported as fully translated.
printf 'Catalogue holds every string in the code…\n'
/usr/bin/python3 - <<'CATALOGUE' || FAIL=1
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("make_catalog", "scripts/make-catalog.py")
make_catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_catalog)          # main() is guarded, so nothing runs
found = json.loads(subprocess.run([sys.executable, "scripts/extract-strings.py"],
                                  capture_output=True, text=True).stdout)
catalogue = json.load(open("resources/Localizable.xcstrings"))["strings"]
missing = [k for k in found if k not in catalogue and k not in make_catalog.SKIP]
for k in missing:
    print(f"  MISSING  the code says it, the catalogue does not: {k[:52]}…")
print(f"  {len(catalogue)} strings")
sys.exit(1 if missing else 0)
CATALOGUE

printf '\n'
if [ "$FAIL" = "1" ]; then
  printf 'Something is not covered. Add the missing check rather than the exception.\n'
  exit 1
fi
printf 'The checks are keeping up.\n'
