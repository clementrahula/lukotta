#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Write the canonical English out in the shape a language file has.

    ./scripts/english-reference.py path/to/en.json

The catalogue holds a translation per language and the source language as the
key itself, so English has no file of its own. A reviewer needs one, in the same
shape as the rest, and generating it means there is nothing to keep in step.
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "en.json")
    catalogue = json.loads(
        (ROOT / "resources" / "Localizable.xcstrings").read_text())["strings"]
    strings, plurals = {}, {}
    for key, entry in catalogue.items():
        unit = entry.get("localizations", {}).get("en", {})
        if "variations" in unit:
            plurals[key] = {
                category: form["stringUnit"]["value"]
                for category, form in unit["variations"]["plural"].items()
            }
        else:
            strings[key] = key
    out.write_text(
        json.dumps({"plurals": plurals, "strings": dict(sorted(strings.items()))},
                   ensure_ascii=False, indent=2) + "\n")
    print(f"  en.json: {len(strings)} strings, {len(plurals)} with plural forms")


if __name__ == "__main__":
    main()
