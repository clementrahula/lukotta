#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Build resources/Localizable.xcstrings from the extracted keys and a language file.

Run once to create the catalogue. After that the catalogue is the source of
truth — the same file Xcode would edit — and this only fills in keys that are
new, so hand edits survive.

A string carrying a count needs one form per plural category, and how many
categories there are is a property of the language, not of the sentence. Those
live under "plurals" in the language file with a form per category.
"""

import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "resources" / "Localizable.xcstrings"

# Names, addresses and format-only keys are not sentences.
SKIP = {
    # Names and addresses.
    "Clement Rahula", "support@lukotta.com", "legal@lukotta.com",
    "bugreport@lukotta.com", "lukotta.com", "rahula.dev",
    # Formats and separators, which carry no words.
    "%@", "%@, %@", "%@, %@, %@", "%@, %@, %@%@", "%@: %@", "%@ · %@", "%@ · %@ · %@",
    "%@ · %@ · %@ · %@", ", ", "-",
    # The bug report is read by whoever fixes the fault, so it stays in one
    # language whatever the interface is set to.
    "yes", "no", "granted", "not granted",
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms):
    return {"variations": {"plural": {k: unit(v) for k, v in forms.items()}}}


def main():
    keys = json.loads((ROOT / sys.argv[1]).read_text()) if len(sys.argv) > 1 else {}
    catalogue = (json.loads(CATALOGUE.read_text())
                 if CATALOGUE.exists()
                 else {"sourceLanguage": "en", "version": "1.0", "strings": {}})
    strings = catalogue.setdefault("strings", {})

    langs = {}
    for path in sorted((ROOT / "translations").glob("*.json")):
        if path.stem.startswith((".", "keys")):
            continue
        langs[path.stem] = json.loads(path.read_text())

    added = 0
    for key in keys:
        if key in SKIP:
            continue
        entry = strings.setdefault(key, {})
        if not entry:
            added += 1
        locs = entry.setdefault("localizations", {})
        for lang, data in langs.items():
            if key in data.get("plurals", {}):
                forms = data["plurals"][key]
                locs["en"] = plural(forms["en"])
                locs[lang] = plural(forms[lang])
            elif key in data.get("strings", {}):
                locs[lang] = unit(data["strings"][key])

    # Anything in the catalogue the code no longer says.
    stale = [k for k in strings if k not in keys and k not in SKIP]

    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(json.dumps(catalogue, indent=2, ensure_ascii=False, sort_keys=True) + "\n")

    translated = {lang: sum(1 for k, e in strings.items()
                            if lang in e.get("localizations", {}))
                  for lang in langs}
    print(f"  {len(strings)} keys ({added} new)")
    for lang, n in translated.items():
        print(f"  {lang}: {n}/{len(strings)} translated")
    if stale:
        print(f"  {len(stale)} no longer in the code:")
        for k in stale[:5]:
            print(f"    {k[:70]}")


if __name__ == "__main__":
    main()
