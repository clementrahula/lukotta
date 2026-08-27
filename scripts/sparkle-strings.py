#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Write Sparkle's own interface into the languages it does not ship.

    ./scripts/sparkle-strings.py <Sparkle.framework> [translations/sparkle]

Sparkle carries 35 localisations. The application has 37. Nine of them --
Bulgarian, Estonian, Filipino, Hindi, Indonesian, Lithuanian, Latvian, Malay
and Albanian -- have none, so a reader who has the whole application in their
own language is asked about updates in English.

macOS resolves a localisation per bundle, not per application: the framework
falling back to English is not something the application's own tables can
answer for. The only place these can go is inside the framework.

That is safe here because build-app.sh re-signs Sparkle.framework, and its
nested XPC services, with this project's identity after the bundle is
assembled. This runs before that, so the signature is made over what it wrote.
Run against an already-signed framework it would invalidate it, which is why
it refuses unless told otherwise.

Sparkle's own translations are partial -- Finnish carries 30 of the 82 -- and a
missing string falls back to English one string at a time. These are complete
per language so no dialog comes out half in one language and half in another.
"""
import json
import pathlib
import plistlib
import subprocess
import sys

ENGLISH = "_english.json"


def strings_file(pairs):
    """A .strings table. Text rather than a binary plist: it diffs."""
    out = ["/* Written by scripts/sparkle-strings.py. Do not edit here. */", ""]
    for key in sorted(pairs):
        k = key.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        v = pairs[key].replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        out.append(f'"{k}" = "{v}";')
    return "\n".join(out) + "\n"


def placeholders(text):
    """Which format specifiers a string uses, in the order they appear."""
    found, i = [], 0
    while i < len(text):
        if text[i] == "%":
            j = i + 1
            while j < len(text) and text[j] not in "@dsflu%":
                j += 1
            if j < len(text):
                found.append(text[i:j + 1])
                i = j
        i += 1
    return [f for f in found if f != "%%"]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    framework = pathlib.Path(sys.argv[1])
    source = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "translations/sparkle")
    resources = framework / "Versions" / "B" / "Resources"
    if not resources.is_dir():
        sys.exit(f"error: no Resources in {framework}")

    english = json.loads((source / ENGLISH).read_text())

    written, problems = [], []
    for path in sorted(source.glob("*.json")):
        if path.name == ENGLISH:
            continue
        lang = path.stem
        pairs = json.loads(path.read_text())

        # A key Sparkle does not look up is dead weight, and a placeholder that
        # does not survive translation is a crash or a wrong number in front of
        # somebody. Both are worth failing the build over.
        for key, value in pairs.items():
            if key not in english:
                problems.append(f"{lang}: {key[:48]!r} is not a Sparkle string")
                continue
            want, got = placeholders(english[key]), placeholders(value)
            if sorted(want) != sorted(got):
                problems.append(
                    f"{lang}: {key[:40]!r} wants {want} but the translation has {got}")

        missing = len(english) - len(pairs)
        target = resources / f"{lang}.lproj"
        target.mkdir(parents=True, exist_ok=True)
        (target / "Sparkle.strings").write_text(strings_file(pairs), encoding="utf-8")
        written.append(f"{lang} ({len(pairs)}/{len(english)})"
                       + (f", {missing} fall back to English" if missing else ""))

    if problems:
        for p in problems:
            print(f"  error: {p}", file=sys.stderr)
        sys.exit(1)

    print(f"  Sparkle speaks {len(written)} more languages: {', '.join(written)}")


if __name__ == "__main__":
    main()
