#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Refuse a changelog written for the person who made the change.

    ./scripts/check-changelog.py releases/1.22.0-beta.2.md
    ./scripts/check-changelog.py            # every releases/*.md

1.22.0-beta.2 went out with sixty commit subjects as its release notes, because
the notes file was named for the version rather than the pre-release and the
script drafted from the log. Nobody caught it before it was published. "Refuse
the two channels that matter, not all four" is a good commit message and means
nothing to somebody installing an app.

So this is mechanical rather than advisory, and it runs before anything is
published on any channel. The tests below are the ones a machine can make
stick; the judgement about whether a line is worth reading stays with a person,
but a line that fails any of these never reaches one.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Commit subjects are imperative. Release notes describe what somebody now
# finds different. Any bullet opening with one of these is being written to the
# wrong reader.
DEVELOPER_VERBS = {
    "apply", "avoid", "clarify", "correct", "deprecate", "ensure", "extract",
    "implement", "prefer", "prevent", "prove", "refactor", "refuse", "reject",
    "rename", "restore", "rule", "separate", "tidy", "widen", "withdraw",
    "wire", "wrap",
}

# Words that belong to whoever builds the thing, never to whoever uses it.
INTERNAL_WORDS = {
    "appcast", "assertion", "backport", "branch", "changelog", "ci", "commit",
    "coverage", "deprecate", "diff", "fixture", "harness", "lint", "linter",
    "merge", "microvm", "rebase", "refactor", "regression", "repo",
    "repository", "revert", "runner", "snapshot", "stub", "todo", "upstream",
    "vendor", "workflow",
}

# Names people actually see: on the box, in Finder, in the app. Written the way
# their owners write them, which is why several look like code and are not.
PRODUCT_NAMES = {
    "macos", "bitlocker", "filevault", "luks", "luks1", "luks2", "ntfs",
    "exfat", "fat32", "ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "apfs",
    "hfs", "finder", "windows", "linux", "ubuntu", "debian", "fedora", "mint",
    "apple", "iphone", "virtualbox", "vmware", "qcow2", "vmdk", "vdi", "vhd",
    "vhdx", "dmg", "img", "raid", "lvm", "usb", "ssd", "nfs", "gb", "mb",
    "tb", "kb", "mib", "gib", "openssl", "sparkle", "homebrew",
}

CODE = re.compile(
    r"`[^`]+`"                 # anything quoted as code
    r"|\b\w+\.(swift|rs|sh|py|md|toml|json|plist|xml)\b"
    r"|\b[a-z]+[A-Z]\w*"       # camelCase
    r"|\b\w+_\w+\b"            # snake_case
    r"|(?<![\w.])/[\w./-]+"    # a path
    r"|\b\w+\(\)"              # a function call
)


def commit_subjects():
    """Every subject in the history, normalised for comparison."""
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "log", "--format=%s", "-n", "4000"],
            capture_output=True, text=True, check=True).stdout
    except Exception:
        return set()
    return {normalise(line) for line in out.splitlines() if line.strip()}


def normalise(text):
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()


def check(path, subjects):
    faults = []
    # Continuation lines are joined back on. Whether a bullet is one line is a
    # formatting question and check-coverage.sh already owns it; this is about
    # who the words were written for.
    bullets = []
    for line in path.read_text(encoding="utf-8").rstrip("\n").split("\n"):
        if line.startswith("- "):
            bullets.append(line[2:].strip())
        elif line.strip() and bullets:
            bullets[-1] += " " + line.strip()

    if not bullets:
        faults.append("no bullets at all")

    for text in bullets:

        # The decisive one. A line that is also a commit subject was written
        # for the wrong reader, whoever wrote it.
        if normalise(text) in subjects:
            faults.append(f"is a commit subject: {text[:66]}")
            continue

        first = re.sub(r"[^a-z]", "", text.split(" ")[0].lower())
        if first in DEVELOPER_VERBS:
            faults.append(f"imperative, like a commit: {text[:56]}")

        for found in CODE.finditer(text):
            hit = found.group(0)
            if re.sub(r"[^a-z0-9]", "", hit.lower()) in PRODUCT_NAMES:
                continue  # a name people read, not an identifier
            faults.append(f"names code or a path ({hit[:24]}): {text[:44]}")
            break

        words = {re.sub(r"[^a-z]", "", w.lower()) for w in text.split()}
        internal = words & INTERNAL_WORDS
        if internal:
            faults.append(f"internal word {sorted(internal)}: {text[:44]}")

    return faults


def main():
    subjects = commit_subjects()
    targets = ([pathlib.Path(a) for a in sys.argv[1:]]
               or sorted((ROOT / "releases").glob("*.md")))
    bad = 0
    for path in targets:
        if not path.exists():
            print(f"  MISSING  {path}")
            bad += 1
            continue
        faults = check(path, subjects)
        if faults:
            bad += 1
            print(f"  REJECTED {path.name}")
            for f in faults[:12]:
                print(f"      {f}")
            if len(faults) > 12:
                print(f"      … and {len(faults) - 12} more")
        else:
            print(f"  ok       {path.name}")
    if bad:
        print("\n  Release notes are read by somebody installing the app, and by")
        print("  nobody else. Say what they will find different, in their words.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
