#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Turn a version's notes into the page Sparkle shows.

    ./scripts/notes-html.py <version> <notes.md> [--heading "Versioon"]

Was a heredoc inside release.sh, and is a file because the same rendering now
has to happen once for English and once for every language somebody has
approved notes in. Two copies of it would drift, and the one that drifted
would be the translated one nobody reads.
"""
import argparse
import html
import pathlib
import re
import sys


HEADING = re.compile(r"^<!--\s*heading:\s*(.+?)\s*-->\s*$", re.MULTILINE)


def render(version, body, heading="Version"):
    """The notes as Sparkle's panel wants them.

    Only lines beginning "- " are notes. Anything above the first of them is
    front matter -- the heading comment a translation carries, a stray blank
    line -- and is dropped rather than shown, because a note nobody wrote is
    worse than a note missing.
    """
    found = HEADING.search(body)
    if found:
        heading = found.group(1)
    body = HEADING.sub("", body).strip()

    first = body.find("- ")
    body = body[first:] if first >= 0 else ""
    items = [re.sub(r"\s+", " ", b).strip()
             for b in re.split(r"\n(?=- )", body) if b.strip()]

    out = ['<html><body style="font: -apple-system-body; margin: 0">',
           f"<h2>{html.escape(heading)} {html.escape(version)}</h2>"]
    if items:
        out.append("<ul>")
        # Escaped, because these are somebody's sentences, not markup. A note
        # mentioning <Enter>, "AT&T" or a comparison of two numbers otherwise
        # produces a panel with half a line missing and a release page to match.
        out += [f"  <li>{html.escape(item.lstrip('- '))}</li>" for item in items]
        out.append("</ul>")
    else:
        out.append("<p>No notes were written for this version.</p>")
    out.append("</body></html>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("notes")
    # Normally taken from a "<!-- heading: … -->" line in the notes
    # themselves, so a translation carries its own word. This overrides that.
    ap.add_argument("--heading", default="Version")
    args = ap.parse_args()

    source = pathlib.Path(args.notes)
    sys.stdout.write(render(args.version,
                            source.read_text() if source.exists() else "",
                            args.heading))


if __name__ == "__main__":
    main()
