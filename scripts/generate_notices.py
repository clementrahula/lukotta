#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Rewrite the guest package table inside THIRD_PARTY_NOTICES.md from
vendor/guest-sbom.json, and touch nothing else in the document.

The SBOM is committed, so this runs from a bare checkout: no vendor tree, no
macOS build. --check renders the table and reports what differs instead of
writing it.

The prose belongs to the document, not to this script. A version that
generated the whole file held its own copy of that prose, which left seven
modification statements the licences require one run away from deletion."""
import json
import re
import sys

HEADING = "## Linux Guest Image"
HEADER = "| Package | Version | Licence |"
RULE = "| --- | --- | --- |"
COUNT = re.compile(r"following (\d+) packages")
ROW = re.compile(r"^\| ([^|]+?) \| ([^|]+?) \| ([^|]+?) \|$")


def rows_from_sbom(path):
    try:
        with open(path, encoding="utf-8") as fh:
            bom = json.load(fh)
    except FileNotFoundError:
        sys.exit(
            f"error: no SBOM at {path}\n"
            "       vendor-engine.sh writes it when it packs a guest, and it "
            "is committed.")
    except json.JSONDecodeError as bad:
        sys.exit(f"error: {path} is not valid JSON: {bad}")
    rows = set()
    for component in bom.get("components", []):
        if component.get("type") != "library":
            continue
        licences = component.get("licenses")
        expression = licences[0]["expression"] if licences else "(unstated)"
        rows.add((component["name"], component.get("version", ""), expression))
    if not rows:
        sys.exit(f"error: no packages in {path}")
    return sorted(rows)


def section_bounds(lines, path):
    try:
        start = lines.index(HEADING)
    except ValueError:
        sys.exit(f"error: {path} has no '{HEADING}' section")
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")),
        len(lines),
    )
    try:
        table = lines.index(HEADER, start, end)
    except ValueError:
        sys.exit(f"error: {path} has no package table under '{HEADING}'")
    after = table + 1
    while after < end and lines[after].startswith("|"):
        after += 1
    return start, end, table, after


def rows_from_notices(lines, table, after):
    rows = set()
    for line in lines[table + 1:after]:
        if line == RULE:
            continue
        match = ROW.match(line)
        if match:
            rows.add(tuple(part.strip() for part in match.groups()))
    return rows


def rewrite(lines, start, table, after, end, rows, path):
    rendered = [HEADER, RULE] + [f"| {n} | {v} | {lic} |" for n, v, lic in rows]
    updated = lines[:table] + rendered + lines[after:]
    shift = len(rendered) - (after - table)
    stated = 0
    for i in range(start, end + shift):
        updated[i], found = COUNT.subn(f"following {len(rows)} packages", updated[i])
        stated += found
    if not stated:
        sys.exit(f"error: {path} has no package count under '{HEADING}'")
    return updated


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    if len(args) != 2:
        sys.exit("usage: generate_notices.py <notices.md> <guest-sbom.json> [--check]")
    notices_path, sbom_path = args

    rows = rows_from_sbom(sbom_path)
    with open(notices_path, encoding="utf-8") as fh:
        original = fh.read()
    lines = original.split("\n")
    start, end, table, after = section_bounds(lines, notices_path)
    updated = "\n".join(
        rewrite(lines, start, table, after, end, rows, notices_path))

    if updated == original:
        print(f"{notices_path}: {len(rows)} packages, agreeing with {sbom_path}")
        return 0

    if check:
        listed = rows_from_notices(lines, table, after)
        differences = 0
        for what, differing in (
            ("only in the SBOM", set(rows) - listed),
            ("only in the notices", listed - set(rows)),
        ):
            for row in sorted(differing):
                differences += 1
                print(f"  {what}: {row[0]} {row[1]} {row[2]}")
        if not differences:
            for line in lines[start:end]:
                if COUNT.search(line):
                    print(f"  the table lists {len(rows)} packages and the text"
                          f" says {COUNT.search(line).group(1)}")
        sys.exit(
            f"error: {notices_path} does not describe the image in {sbom_path}.\n"
            "       Run scripts/generate-notices.sh to bring it back into "
            "agreement. It needs nothing but this checkout.")

    with open(notices_path, "w", encoding="utf-8") as fh:
        fh.write(updated)
    print(f"{notices_path}: {len(rows)} packages, from {sbom_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
