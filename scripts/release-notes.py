#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""What changed in a version, read from the history rather than remembered.

    ./scripts/release-notes.py 1.18.1                  # to stdout
    ./scripts/release-notes.py 1.18.1 --write          # to releases/1.18.1.md
    ./scripts/release-notes.py 1.18.1 --since v1.15.2  # from a given version

Release notes were written by hand, which meant they could be forgotten and
they could be copied. Both happened: three versions went out carrying the same
six lines, one of those files was the previous version's under a new name, and
fifty tags had no file at all. A file that has to be remembered is a file that
will be wrong, and the check that catches a copy only tells somebody they have
already made the mistake.

So the starting point is derived. Every commit since the previous version is
already a sentence saying what it did -- that is the house rule for commit
messages -- and the ones that changed something a person can see are the notes.
Nothing is invented here and nothing is summarised: each line is a commit
subject, and the version it belongs to is the range it was taken from, which
cannot be the same range twice.

It is a draft, not the finished text. `bump-version.sh` writes it with the
version, so it is in the repository from the moment the version exists and can
be edited into whatever reads best before the release goes out.

Where it reads from matters as much as what it keeps. By default it is the
previous version tag, which is what a version's own notes are. A release covers
what the people receiving it have not seen, which is everything since the last
version actually published -- three versions may have been tagged and never
released -- so `release.sh` hands it that one with --since.

What counts as visible is a path rather than a judgement: the app's own code,
the translations, the resources it carries, the patches to the engine, the
engine it is pinned to, and the script that assembles the bundle. A commit
touching only tests, tooling, documents or these scripts changed nothing anybody
using the app can see, and saying so in a release note wastes the one place they
are paying attention.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

# Everything the built app is made of. A change anywhere here can reach
# somebody using it; a change anywhere else cannot.
SHIPS = (
    "sources/",
    "resources/",
    "translations/",
    "patches/",
    "vendor/engine.lock",
    "build-app.sh",
)

ROOT = pathlib.Path(__file__).resolve().parent.parent


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        check=True, capture_output=True, text=True,
    ).stdout


def as_version(tag: str) -> tuple[int, ...] | None:
    """(1, 18, 1) from "v1.18.1", or None from anything else."""
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag.strip())
    return tuple(int(part) for part in match.groups()) if match else None


def previous_tag(version: str) -> str | None:
    """The newest version tag below this one.

    Below rather than "the last tag made": tags are sorted by what they name
    and not by when they were written, so a patch released out of order still
    reads from the version it followed.
    """
    want = as_version(f"v{version}")
    if want is None:
        sys.exit(f"error: {version} is not a version")
    below = [
        (numbers, tag)
        for tag in git("tag", "--list", "v*").split()
        if (numbers := as_version(tag)) is not None and numbers < want
    ]
    return max(below)[1] if below else None


def changed_what_ships(commit: str) -> bool:
    paths = git("show", "--name-only", "--format=", commit).split("\n")
    return any(path.startswith(SHIPS) for path in paths if path)


def notes(version: str, since: str | None = None) -> list[str]:
    since = since or previous_tag(version)
    # The version's own tag when it has one, so that notes written after a
    # later version was tagged do not swallow that version's commits.
    until = f"v{version}" if git("tag", "--list", f"v{version}").strip() else "HEAD"
    span = f"{since}..{until}" if since else until

    lines = []
    for entry in git("log", "--no-merges", "--reverse", "--format=%H\t%s", span).split("\n"):
        if not entry.strip():
            continue
        commit, subject = entry.split("\t", 1)
        if changed_what_ships(commit):
            lines.append(f"- {subject.rstrip('.')}.")
    return lines


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: release-notes.py <version> [--write]")
    version = sys.argv[1]
    since = None
    if "--since" in sys.argv:
        at = sys.argv.index("--since")
        if len(sys.argv) <= at + 1:
            sys.exit("usage: release-notes.py <version> [--since <ref>] [--write]")
        since = sys.argv[at + 1]
    lines = notes(version, since)
    if not lines:
        # A version with nothing visible in it is a version nobody needs to
        # read about, but Sparkle shows this panel either way.
        lines = ["- Fixes and improvements under the surface."]
    text = "\n".join(lines) + "\n"

    if "--write" not in sys.argv:
        sys.stdout.write(text)
        return

    target = ROOT / "releases" / f"{version}.md"
    target.parent.mkdir(exist_ok=True)
    if target.exists() and target.read_text().strip():
        print(f"  releases/{version}.md is already written; left alone")
        return
    target.write_text(text)
    print(f"  wrote releases/{version}.md, {len(lines)} lines from the history")


if __name__ == "__main__":
    main()
