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

# 1. Every screen has baselines: English at both sizes in both appearances, and
#    one picture in each of the four languages that stress a layout differently.
printf 'Screens with baselines…\n'
# From inside scenes() only: the geometries and the appearances are pairs of
# the same shape further down the file.
scenes=$(/usr/bin/python3 -c '
import re
text = open("sources/Lukotta/Snapshots.swift").read()
body = text.split("static func scenes()", 1)[1]
# Only as far as the next function: the geometries and the appearances further
# down the file are pairs of the same shape.
# Indentation-agnostic: the file is wrapped in #if DEVTOOLS in some builds,
# and a formatter indents everything inside it by four more spaces.
body = re.split(r"\n\s+(?:@MainActor\n\s+)?(?:private )?static (?:func|let|var) ", body)[0]
print("\n".join(sorted(set(re.findall(r"\(\s*\n?\s*\"([a-z0-9-]+)\",", body)))))
')
for scene in $scenes; do
  missing=""
  for size in ideal min; do
    for mode in light dark; do
      [ -f "tests/snapshots/${scene}-${size}-${mode}.png" ] || missing="yes"
    done
  done
  for lang in de ar ja hi; do
    [ -f "tests/snapshots/${lang}-${scene}-ideal-light.png" ] || missing="yes"
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

# 7. Every string has context, every screen it names exists, and every
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
# 8. A changelog is a few short lines of plain language.
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

# 9. Nothing is translated before the English has been approved.
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

printf '\nv2 and v1 cannot reach each other…\n'
# 10. The rewrite is developed in the same repository as the application people
#     are running, for months, and may never ship. The one thing it may never
#     do is disturb v1 -- not its installed copies, not its daemon, not its
#     saved passphrases, not its feed, not its build numbers. That separation
#     is two facts and nothing else: every channel is a different application
#     down to its identifier, and nothing is ever published from the v2 branch.
#     Both are checked here because both are one careless line from gone.
/usr/bin/python3 - <<'CHANNELS' || FAIL=1
import pathlib, re, sys

text = pathlib.Path("build-app.sh").read_text()
start = text.index('case "${LUKOTTA_BRANDING:-unbranded}" in')
block = text[start:text.index("\nesac", start)]

# Each arm of the case, as the values it sets. A channel that sets none of them
# is the error arm, which has no identity to collide with.
channels = {}
for arm in re.split(r"\n  (\w+)\)\n", block)[1:]:
    if arm in ("official", "beta", "dev", "v2", "unbranded"):
        name = arm
        continue
    values = dict(re.findall(r'^\s*(APP_NAME|BUNDLE_ID|HELPER_NAME|FEED_URL|AUTO_CHECKS)="([^"]*)"',
                             arm, re.M))
    if values:
        channels[name] = values

missing = [c for c in ("official", "beta", "dev", "v2", "unbranded") if c not in channels]
if missing:
    print(f"  MISSING  build-app.sh defines no {', '.join(missing)} channel")
    sys.exit(1)

# Every one of these keys something macOS separates for us, and only because
# the values differ: preferences, the Keychain service holding passphrases, the
# log subsystem, Sparkle's cache, the daemon's label, Application Support, and
# the copy in /Applications. Two channels sharing one is two applications
# standing on each other, and the one that loses is whichever ran last.
for key in ("APP_NAME", "BUNDLE_ID", "HELPER_NAME"):
    seen = {}
    for channel, values in channels.items():
        seen.setdefault(values.get(key, ""), []).append(channel)
    for value, sharers in seen.items():
        if len(sharers) > 1:
            print(f"  SHARED  {' and '.join(sorted(sharers))} both use {key}={value}")
            sys.exit(1)

# The rewrite must not check for updates. Every feed that exists carries v1, so
# a v2 build that looked would be offered a v1 release and would take it.
if channels["v2"].get("AUTO_CHECKS") != "false":
    print("  MISSING  the v2 channel must set AUTO_CHECKS=false; every feed carries v1")
    sys.exit(1)
for other in ("official", "beta"):
    if channels["v2"].get("FEED_URL") == channels[other].get("FEED_URL"):
        print(f"  SHARED  v2 and {other} name the same feed")
        sys.exit(1)

print(f"  {len(channels)} channels, none sharing a name, an identifier or a daemon")
CHANNELS
# Nothing is published from the v2 branch. The guard is in release.sh; this is
# here so that it cannot quietly come back out.
if /usr/bin/grep -qE '^\s*v2 \| v2/\*\)' "$HERE/scripts/release.sh"; then
  printf '  release.sh publishes nothing from the v2 branch\n'
else
  printf '  MISSING  release.sh must refuse to release from the v2 branch\n'
  FAIL=1
fi

# Things the source declares and nothing but a test ever calls.
#
# Three of those cost a morning: a mount option parsed, tested four ways and
# never asked, so `-o ro` got a writable volume; the whole path from the
# application to the filesystem extension, so no drive was ever handed to it;
# and the arithmetic that turns a write into whole blocks, without which every
# write would have failed the first time it met a real disk.
#
# Tests are not use. A function only a test calls is a function whose behaviour
# is guaranteed and whose absence from the product is not noticed.
printf 'Nothing important is only called by its own test…\n'
/usr/bin/python3 - "$HERE" <<'CALLED' || FAIL=1
import pathlib, re, sys

here = pathlib.Path(sys.argv[1])
# The ones that must be reached from the product, named rather than inferred:
# each was once declared and uncalled, and each cost something.
required = {
    "isReadOnly": "a read-only mount would be written to",
    "isAligned": "every write would fail on a real block device",
    "covering": "an unaligned write would go to the wrong place",
    "offsetWithinBlocks": "the bytes would be trimmed out of the wrong offset",
}

# Known to be uncalled, on purpose, with the reason. Listed rather than
# forgotten: an acknowledged gap that is printed every run is a different thing
# from one nobody can see. When one of these is wired up it moves to `required`
# above, and this list is meant to empty.
pending = {
    "attempt": (
        "ExtensionMount.attempt: no drive reaches the filesystem extension yet. "
        "The call belongs in Mounter, which is the v1 path, and it should be made "
        "by somebody who can then plug a drive in and watch."
    ),
}

sources = [
    f for f in here.glob("sources/Lukotta*/*.swift") if "Tests" not in str(f)
]
text = "\n".join(f.read_text() for f in sources)

missing = []
for name, cost in required.items():
    declared = len(re.findall(r"func " + re.escape(name) + r"\s*\(", text))
    used = len(re.findall(r"\b" + re.escape(name) + r"\s*\(", text))
    if used <= declared:
        missing.append(f"  UNCALLED  {name}() is declared and never used: {cost}")

if missing:
    print("\n".join(missing))
    sys.exit(1)
print(f"  {len(required)} of them, every one reached from the product")

for name, why in pending.items():
    declared = len(re.findall(r"func " + re.escape(name) + r"\s*\(", text))
    used = len(re.findall(r"\b" + re.escape(name) + r"\s*\(", text))
    if used > declared:
        print(f"  {name}() is wired up now; move it to the required list")
        sys.exit(1)
    print(f"  still to wire -- {why}")
CALLED

if [ "$FAIL" = "1" ]; then
  printf 'Something is not covered. Add the missing check rather than the exception.\n'
  exit 1
fi
printf 'The checks are keeping up.\n'
