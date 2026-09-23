#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Are the checks keeping up with the app?
#
#   ./scripts/check-coverage.sh
#
# Tests rot by omission rather than by breaking: a rule is written and nothing
# exercises it, a format is claimed and no end-to-end run opens one. Each of those leaves the
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

# 1. Every failure rule is exercised. A rule nobody tests is a rule that stops
#    firing when upstream rewords its output, and nothing says so.
printf 'Failure rules with a test…\n'
# SCRIBE: say why this one takes `|| true` AND an emptiness check, where the
# caller count further down needs only the `|| true`. There, finding nothing is
# an answer -- no harness calls this script -- and the rule acts on it. Here,
# finding nothing means the pattern has moved and the rule is reading a shape
# no longer in the file, which is the refactor it exists to survive: rewording
# `name:` to `label:` made grep match nothing, the failing pipeline ended the
# run under `set -e` after the header and before any other rule, and `|| true`
# on its own would have turned that mute red into a mute green -- every rule in
# this script passed and none of them run. So zero is refused out loud.
rules="$(grep -oE 'name: "[a-z0-9-]+", source:' sources/LukottaCore/Diagnosis.swift \
  | sed -E 's/name: "([a-z0-9-]+)".*/\1/' | sort -u || true)"
if [ -z "$rules" ]; then
  bad "no failure rule found in sources/LukottaCore/Diagnosis.swift: this rule is matching nothing, so it proves nothing"
else
  for rule in $rules; do
    grep -q "\"$rule\"" sources/LukottaTests/main.swift || bad "nothing tests the \"$rule\" rule"
  done
  note "$(printf '%s\n' "$rules" | wc -l | tr -d ' ') rules"
fi

# 2. Every image format the app claims is opened by the end-to-end run. The
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

# 3. Every language has every string. A half-translated release shows English
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

# 4. Every string the code shows is in the catalogue. Check 3 compares the
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

# 5. Every string has context, every screen it names exists, and every
#    translation keeps the placeholders the English has. A translator reading a
#    string alone cannot tell a button from a sentence; a placeholder that has
#    gone puts the wrong value on screen or none at all.
printf 'Context for every string, placeholders intact…\n'
/usr/bin/python3 - <<'CONTEXT' || FAIL=1
import json, pathlib, re, sys

catalogue = json.load(open("resources/Localizable.xcstrings"))["strings"]
context = json.load(open("translations/context/strings.json"))["strings"]
screens = set(json.load(open("translations/context/screens.json"))["screens"])
bad = 0

for key in catalogue:
    entry = context.get(key)
    if entry is None:
        print(f"  MISSING  no context for: {key[:52]}…"); bad += 1; continue
    if not entry.get("context"):
        print(f"  MISSING  context is empty for: {key[:48]}…"); bad += 1
    for screen in entry.get("screens", []):
        if screen not in screens:
            print(f"  MISSING  no such screen '{screen}' for: {key[:40]}…"); bad += 1
for key in context:
    if key not in catalogue:
        print(f"  MISSING  context for a string nothing says: {key[:44]}…"); bad += 1

# %@ and %lld, in either the plain or the positional form.
token = re.compile(r"%(?:\d+\$)?(?:@|lld)")
def shape(text):
    return sorted(t.replace("1$", "").replace("2$", "").replace("3$", "")
                  for t in token.findall(text))

for path in sorted(pathlib.Path("translations").glob("*.json")):
    language = path.stem
    data = json.loads(path.read_text())
    for key, value in data.get("strings", {}).items():
        if key not in catalogue:
            continue
        if shape(key) != shape(value):
            print(f"  MISSING  {language}: placeholders differ for: {key[:40]}…")
            bad += 1
print(f"  {len(context)} strings with context, {len(screens)} screens")
sys.exit(1 if bad else 0)
CONTEXT

printf '\n'
# 6. A changelog is a few short lines of plain language.
#
#    Enforced rather than remembered. Every draft of these notes has come back
#    too long: a paragraph per item, the mechanism, thresholds in seconds,
#    component names. Nobody reading an update dialog wants any of it, and a
#    style rule nobody can run is a style rule that lasts one release.
#
#    A bullet is one line. That is the whole trick: a line that has to fit
#    cannot hold an explanation, and wrapping is how the paragraphs got in.
printf 'The changelog is short and plain…\n'
/usr/bin/python3 - <<'NOTES' || FAIL=1
import pathlib, re, sys

MAX_BULLETS = 8
MAX_CHARS = 100

# The version being worked towards, and any pre-release of it. Notes already
# published are a record of what shipped and are left exactly as they are;
# rewriting them to satisfy a rule added later would be a lie about history.
version = pathlib.Path("VERSION").read_text().strip()
current = [p for p in [pathlib.Path(f"releases/{version}.md")] if p.exists()]

bad = False
for path in current:
    lines = path.read_text(encoding="utf-8").rstrip("\n").split("\n")
    if not lines or not lines[0].startswith("- "):
        continue
    bullets = [l for l in lines if l.startswith("- ")]
    wrapped = [l for l in lines if l and not l.startswith("- ")]
    if wrapped:
        print(f"  TOO LONG  {path.name}: {len(wrapped)} wrapped line(s); "
              f"a bullet is one line")
        bad = True
    if len(bullets) > MAX_BULLETS:
        print(f"  TOO MANY  {path.name}: {len(bullets)} bullets, at most {MAX_BULLETS}")
        bad = True
    for b in bullets:
        if len(b) > MAX_CHARS:
            print(f"  TOO LONG  {path.name}: {len(b)} chars in \"{b[2:42]}…\"")
            bad = True

print(f"  {len(current)} changelog(s) for {version}")
sys.exit(1 if bad else 0)
NOTES

# 7. Nothing is translated before the English has been approved.
#
#    Translating a draft wastes the work when a line changes, and puts the
#    owner in front of thirty-six files they never agreed to. The order is:
#    write, de-slop, approve, translate. Enforced here because an order that
#    lives in somebody's head is an order that gets skipped when it is late.
printf 'Translations come after approval…\n'
/usr/bin/python3 - <<'ORDER' || FAIL=1
import hashlib, pathlib, sys

version = pathlib.Path("VERSION").read_text().strip()
notes = pathlib.Path(f"releases/notes/{version}")
if not notes.is_dir():
    print("  nothing translated yet")
    sys.exit(0)

english = pathlib.Path(f"releases/{version}.md")
if not english.exists():
    print(f"  TRANSLATED WITHOUT NOTES  releases/notes/{version}/ exists, {english} does not")
    sys.exit(1)

digest = hashlib.sha256(english.read_bytes()).hexdigest()[:12]
approved = {}
for line in pathlib.Path("releases/APPROVED").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) == 2:
        approved[parts[0]] = parts[1]

if version not in approved:
    print(f"  NOT APPROVED  {len(list(notes.glob('*.md')))} translations exist, "
          f"{version} is not in releases/APPROVED")
    sys.exit(1)
if approved[version] != digest:
    print(f"  CHANGED SINCE APPROVAL  approved {approved[version]}, notes now {digest}; "
          f"the translations describe text nobody approved")
    sys.exit(1)

print(f"  {len(list(notes.glob('*.md')))} translations, English approved as {digest}")
ORDER

printf '\nA branded build is not copied into /Applications…\n'
# A release or a pre-release installed over the top of the copy on this Mac
# destroys the version somebody would have updated *from*, and proves nothing
# about the update path that is the thing being shipped. It happened to a beta
# in the middle of testing that very update. The guard is in build-app.sh; this
# is here so it cannot quietly come back.
if /usr/bin/grep -qE '^\s*official \| beta\) MAY_INSTALL=false' "$HERE/build-app.sh" \
    && /usr/bin/grep -qE 'LUKOTTA_INSTALL:-1.*=.*"1".*MAY_INSTALL.*=.*"true"' \
      "$HERE/build-app.sh"; then
  printf '  build-app.sh installs neither the release nor the pre-release\n'
else
  printf '  MISSING  build-app.sh must not copy an official or beta build into /Applications\n'
  FAIL=1
fi
if /usr/bin/grep -qE '^\s*(rm -rf|/usr/bin/ditto).*"?/Applications/' "$HERE/scripts/release.sh"; then
  printf '  MISSING  release.sh must never write into /Applications\n'
  FAIL=1
else
  printf '  release.sh writes nothing into /Applications\n'
fi
if /usr/bin/grep -q 'LUKOTTA_INSTALL=0' "$HERE/scripts/release.sh"; then
  printf '  release.sh says so at the call site too\n'
else
  printf '  MISSING  release.sh must pass LUKOTTA_INSTALL=0 to build-app.sh\n'
  FAIL=1
fi
# update-test.sh is the exception, and deliberately so: driving Sparkle against
# the installed pre-release *is* the update mechanism, and it keeps a copy of
# what was there and puts it back. Nothing else may replace an installed app.
for s in "$HERE"/scripts/*.sh; do
  case "$(basename "$s")" in update-test.sh|check-coverage.sh) continue ;; esac
  if /usr/bin/grep -qE '/usr/bin/ditto[^|]*"?/Applications/' "$s"; then
    printf '  MISSING  %s replaces an installed app\n' "$(basename "$s")"
    FAIL=1
  fi
done

# The rules below count as much as the ones above: the verdict is at the end of
# the file, after the last of them. Nothing exits before it.

# 8. Every harness is reachable from the registry, directly or through one
#     that is.
#
#     A harness that runs nowhere is prose with a shebang. corrupt-corpus.sh put
#     83 deliberately broken NTFS images through the app's own ladder, its
#     numbers sat in SPECS.md as settled fact, and nothing ran it: when it was
#     finally registered and run on 2026-09-05 it reached no image at all,
#     because its default named a build that has no --drive and the call it hung
#     on had no timeout. It had been that way long enough for nobody to know.
#
#     The tooling list is written out rather than guessed. A rule that infers
#     which scripts are claims is a rule that quietly stops firing; naming them
#     makes a new script force the decision -- put it in the registry, or say
#     here why it is not a claim.
printf 'Harnesses something actually runs…\n'
# Build and release steps, and five probes that take arguments: each needs a
# volume or an image named on the command line and exists to be pointed at
# something during an investigation. A probe is not a claim -- it has no fixture
# of its own and renders no verdict -- so registering one would put a row in the
# table that cannot say whether it holds.
tooling="build-app build-engine build-ntfsck bump-version check-coverage
check-engine-updates collect-sources fetch-engine generate-notices lint
make-dmg make-format-volumes make-test-volumes notary-status release
run-tests screenshots ship sparkle-keys translation-bundle
vendor-engine verify verify-goal
cross-guest-copy finder-parity flush-reaches-drive thread-starvation watch-for-complaints"
unreached=0
for script in scripts/*.sh; do
  name="$(basename "$script" .sh)"
  # Newlines to spaces without an echo: the list is written over several
  # lines to stay readable, and the pattern below matches on spaces.
  case " ${tooling//$'\n'/ } " in *" $name "*) continue ;; esac
  # Named by a row, or called by another harness. Called-by is enough: the
  # caller is what the registry runs, and a helper is not a claim of its own.
  if /usr/bin/grep -q -- "$name\.sh" scripts/checks.tsv 2>/dev/null; then continue; fi
  # Both greps find nothing in exactly the case this rule exists for, pipefail
  # fails the pipeline on that, and `set -e` ends the script on an assignment
  # from a failing substitution. Without the `|| true` the rule dies one line
  # before it can name the orphan it was written to catch.
  callers="$(/usr/bin/grep -l -- "$name\.sh" scripts/*.sh 2>/dev/null \
    | /usr/bin/grep -v "scripts/$name.sh" | wc -l | tr -d ' ' || true)"
  # SCRIBE: this guard and the verdict below are if/then, and the reason once
  # written here was wrong -- worth correcting rather than deleting, because the
  # wrong rule is the plausible one. `[ … ] && continue` does not end a run
  # under `set -e`: bash exempts every command of an && list but the last, so
  # the failing test is exempt and the line above it was the whole fault.
  # Measured both ways -- put the `|| true` back and the old && lists behave
  # exactly as these do. They are if/then because the reader should not have to
  # know that exemption to see that the rule can speak.
  if [ "${callers:-0}" -gt 0 ]; then continue; fi
  bad "nothing runs $name.sh: it is in no row and no harness calls it"
  unreached=$((unreached + 1))
done
if [ "$unreached" -eq 0 ]; then note "every harness is reached"; fi

# 9. The licence statements written by hand hold. The guest package table is
#     rendered from the SBOM and checked against it, so it cannot go stale; the
#     revision and licence the notices name and the date on every patch are
#     typed, and each is a licence statement. So each is checked against what it
#     describes rather than re-read and believed.
printf '\nWhat is redistributed says which source it is…\n'
if ! /usr/bin/python3 - <<'PY'
import json, pathlib, re, sys

bad = 0
lock = json.load(open("vendor/engine.lock"))
revision = lock["ntfsprogs_plus"]["revision"]
licence = lock["ntfsprogs_plus"]["licence"]

notices = pathlib.Path("THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
row = re.search(r"^\| ntfsprogs-plus [^|]*\| ([^|]+?) \| ([^|]+?) \|", notices, re.M)
if not row:
    print("  MISSING  THIRD_PARTY_NOTICES.md does not list ntfsprogs-plus")
    bad = 1
else:
    if revision not in row.group(1):
        print(f"  MISSING  the notices say {row.group(1).strip()};"
              f" vendor/engine.lock pins {revision}")
        bad = 1
    if row.group(2).strip() != licence:
        print(f"  MISSING  the notices say {row.group(2).strip()};"
              f" vendor/engine.lock says {licence}")
        bad = 1

start = re.compile(r"^(diff |--- |Index: )", re.M)
dated = re.compile(r"Modified on \d{4}-\d{2}-\d{2}")
patches = sorted(pathlib.Path(".").glob("patches/*.patch")) + \
          sorted(pathlib.Path(".").glob("vendor/patches/*.patch"))
for patch in patches:
    text = patch.read_text(encoding="utf-8", errors="replace")
    head = start.search(text)
    header = text[:head.start()] if head else text
    added = any(dated.search(line) for line in text.splitlines()
                if line.startswith("+"))
    if not dated.search(header) and not added:
        print(f"  MISSING  {patch} records no date, and section 5(a) wants one")
        bad = 1

if not bad:
    print(f"  {len(patches)} patches, each dated; ntfsck at {revision[:7]}")
sys.exit(bad)
PY
then
  FAIL=1
fi

if [ "$FAIL" = "1" ]; then
  printf 'Something is not covered. Add the missing check rather than the exception.\n'
  exit 1
fi
printf 'The checks are keeping up.\n'
