#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Refuse to let anything of the owner's into the repository.

    ./scripts/check-private.py            everything git tracks
    ./scripts/check-private.py --staged   only what is about to be committed
    ./scripts/check-private.py --forget   drop what this machine has remembered

Run from .githooks/pre-commit before a commit exists, from lint.sh, and from
CI. The hook is the one that matters: what reaches history costs a rewrite of
every commit to remove, and a force-push over whatever anybody had cloned.

This is not a secret scanner. The secrets of this project are not in it and
never have been — the signing key, the notarisation credential and the Sparkle
private key live in the keychain, and only Sparkle's *public* key is on disk.
gitleaks covers tokens and private keys in case one ever appears.

What this looks for is the other thing, the one no scanner can know: real
output from the owner's machine pasted into a fixture. A drive's UUID, a home
directory with a real name in it, a recovery key that is genuinely well-formed.
None of it looks like a secret. All of it identifies a person, or an object they own.

Every rule below is one that has actually caught something.
"""
import getpass
import hashlib
import os
import re
import socket
import subprocess
import sys

# Names a fixture may use. Anything else is somebody's real account.
# "kim" is invented, and short on purpose: it stands in for a home directory in
# the pictures drawn for the listings, where a longer one pushes the mount point
# past the width of the window and every path comes out with an ellipsis in it.
ALLOWED_USERS = {"someone", "u", "Shared", "kim"}

# Values that are deliberately in the repository, each shaped like the real
# thing so the code around it is exercised, none of it anyone's.
ALLOWED = {
    # Recovery keys, invented here. Both satisfy BitLocker's rules — they have
    # to, or the validator tests would prove nothing.
    "110011-220022-330033-440044-550055-660066-700007-711711",
    "121121-131131-141141-151151-161161-171171-181181-191191",
    "110011220022330033440044550055660066700007711711",
    "121121131131141141151151161161171171181181191191",
    # A team identifier, invented. The real one is read from the running
    # bundle's own signature, never written down.
    "A1B2C3D4E5",
    # A partition UUID, invented.
    "7A2E4F10-3C58-4D9B-A6E1-2F7C05B34D88",
}

SKIP_DIRS = ("tests/snapshots/", "assets/", "resources/", "translations/", "vendor/")
# Nothing is exempt, this file included. It was, briefly, because it contained
# examples of what it hunts for; an account name in a comment then went in
# under that exemption. The rules are written so they do not match themselves
# instead — which is the only version of this that can be trusted.
SKIP_FILES = ()
SKIP_SUFFIXES = (".png", ".icns", ".car", ".zip", ".gz", ".xz", ".crate", ".xcstrings")

KEY_GROUPS = re.compile(r"\b\d{6}(?:-\d{6}){7}\b")
KEY_RUN = re.compile(r"\b\d{48}\b")
HOME_PATH = re.compile(r"/Users/([A-Za-z0-9_.-]+)")
# As `mount` prints it, inside the options: "(nfs, nodev, mounted by someone)".
# Loose, this matched English prose — "mounted by a virtual machine", "mounted
# by macOS" — and a check that cries wolf gets switched off.
MOUNTED_BY = re.compile(r"mounted by ([A-Za-z0-9_.-]+)\)")
UUID = re.compile(r"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b")
# The word is matched either case; what follows is not, or every ten-letter
# word in a sentence about teams became a signing identifier.
TEAMISH = re.compile(
    r"(?i:subject\.OU|leaf\[subject|team[a-z]*)[\]\s=:\"'\\\\]*([A-Z0-9]{10})\b"
)
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")
# Assembled rather than written out: spelled in full, this line was itself a
# run of characters the rule matches, and the file could not be committed. The
# first answer to that was to exempt this file from its own rules, which is how
# an account name in a comment above got past it.
_PREFIXES = ("ghp_", "gho_", "ghs_", "github_pat_", "sk-ant-", "xoxb-", "AKIA", "ASIA")
TOKENISH = re.compile(r"\b(?:" + "|".join(_PREFIXES) + r")" + r"\S{10,}")


def well_formed_key(text: str) -> bool:
    """Whether this is a recovery key BitLocker itself would accept.

    Every group divisible by eleven, and the quotient inside sixteen bits. A
    key someone made up by typing digits fails this; a key off a real drive
    does not. That is the whole difference, and it is why a key cannot be
    judged by looking at it.
    """
    groups = [int(g) for g in re.split(r"[- ]", text) if g.isdigit()]
    if len(groups) != 8:
        groups = [int(text[i : i + 6]) for i in range(0, 48, 6)] if text.isdigit() else []
    if len(groups) != 8:
        return False
    return all(g % 11 == 0 and g // 11 <= 65535 for g in groups)


def this_machine() -> list:
    """Whoever is at this keyboard, and whatever this Mac calls itself.

    Asked of the system every run, never written down. The rules above know
    which names a fixture may use; these know the names it may not, whoever is
    running it. Nobody's identifiers are recorded here, in the repository or
    beside it — that is the point of the exercise.
    """
    names = []
    user = getpass.getuser()
    if user and user not in ALLOWED_USERS:
        names.append((user, "the account this is running as"))
    host = socket.gethostname().split(".")[0]
    if host and host.lower() not in ("localhost",):
        names.append((f"{host}.local", "this Mac's name on the network"))
    return names


def record_path():
    """Where the digests live: inside .git, and provably outside the work tree.

    Written on demand and never by hand, so there is nothing to ship, nothing
    to review and nothing to forget about. Anywhere git can see is refused
    outright rather than trusted not to be committed — a file like this one
    belongs to the machine, not to the project.
    """
    try:
        git_dir = subprocess.run(
            ["git", "rev-parse", "--absolute-git-dir"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    record = os.path.join(git_dir, "private-disk-digests")
    inside = os.path.commonpath([os.path.realpath(record), os.path.realpath(top)])
    if inside == os.path.realpath(top) and ".git" not in os.path.realpath(record).split(os.sep):
        # Somewhere git could pick it up. Do without the record rather than
        # leave one lying in the tree.
        return None
    return record


def digest(value: str) -> str:
    """A UUID reduced to something that cannot be read back."""
    return hashlib.sha256(value.upper().encode()).hexdigest()


def local_disk_uuids() -> set:
    """Every UUID belonging to a disk attached to this Mac.

    The check that would have caught the one that got through: a drive's
    partition UUID is not secret, not credential-shaped, and identifies a
    physical object its owner keeps. Only a machine with the disk in it can
    know, so this finds nothing in CI and everything on the desk where the
    fixture was captured.
    """
    if sys.platform != "darwin":
        return set()
    # One spawn, not one per device. Asking diskutil about each disk in turn
    # cost seven seconds of every commit, nearly all of it waiting; `info -all`
    # prints the same lines in one and a quarter.
    try:
        info = subprocess.run(
            ["/usr/sbin/diskutil", "info", "-all"],
            capture_output=True,
            text=True,
            timeout=60,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    found = set()
    for line in info.splitlines():
        if "UUID" in line:
            found.update(UUID.findall(line))
    return found


def remembered_uuids(live: set) -> set:
    """Digests of every disk UUID this Mac has shown, not the UUIDs.

    A fixture is captured with the drive attached and committed after it has
    been put away — which is exactly when asking the machine what is attached
    answers nothing. So each run writes down what it saw.

    What it writes down is a hash. Keeping a list of somebody's hardware
    identifiers in order to stop those identifiers being written down would be
    a poor joke; a digest compares just as well and is not the thing. The file
    lives inside .git, is never committed, and never leaves the machine.
    """
    record = record_path()
    if record is None:
        return {digest(u) for u in live}
    known = {digest(u) for u in live}
    try:
        with open(record) as f:
            known.update(line.strip() for line in f if line.strip())
    except OSError:
        pass
    if known:
        try:
            with open(record, "w") as f:
                f.write("\n".join(sorted(known)) + "\n")
        except OSError:
            pass
    return known


def tracked_files() -> list:
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout
    return [p for p in out.splitlines() if p]


def staged_files() -> list:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [p for p in out.splitlines() if p]


def contents(path: str, staged: bool) -> str:
    """What is about to be committed, or what is on disk."""
    if staged:
        r = subprocess.run(["git", "show", f":{path}"], capture_output=True)
        if r.returncode != 0:
            return ""
        blob = r.stdout
    else:
        try:
            blob = open(path, "rb").read()
        except OSError:
            return ""
    if b"\0" in blob[:8000]:
        return ""
    return blob.decode("utf-8", "replace")


def interesting(path: str) -> bool:
    if path in SKIP_FILES or path.endswith(SKIP_SUFFIXES):
        return False
    return not path.startswith(SKIP_DIRS)


def check(path: str, text: str, disks: set, mine: list) -> list:
    found = []

    def say(line_no, what, value):
        found.append((path, line_no, what, value))

    for n, line in enumerate(text.splitlines(), 1):
        for match in KEY_GROUPS.findall(line) + KEY_RUN.findall(line):
            if match in ALLOWED:
                continue
            if well_formed_key(match):
                say(n, "a recovery key BitLocker would accept", match)

        for user in HOME_PATH.findall(line):
            if user not in ALLOWED_USERS:
                say(n, "a home directory belonging to somebody", f"/Users/{user}")

        for user in MOUNTED_BY.findall(line):
            if user not in ALLOWED_USERS:
                say(n, "an account name from a real mount", f"mounted by {user}")

        for uuid in UUID.findall(line):
            if digest(uuid) in disks and uuid not in ALLOWED:
                say(n, "the UUID of a disk attached to this Mac", uuid)

        for team in TEAMISH.findall(line):
            if team not in ALLOWED:
                say(n, "something shaped like a signing team", team)

        for value, what in mine:
            # As a word of its own: an account called "swift" must not condemn
            # every line that mentions the language.
            if re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(value) + r"(?![A-Za-z0-9_-])", line):
                say(n, what, value)

        if PRIVATE_KEY.search(line):
            say(n, "a private key", "-----BEGIN … PRIVATE KEY-----")
        for token in TOKENISH.findall(line):
            say(n, "an access token", token[:12] + "…")

    return found


def main(argv: list) -> int:
    if "--forget" in argv:
        record = record_path()
        if record and os.path.exists(record):
            os.unlink(record)
            print(f"  forgot every disk this Mac had shown ({record})")
        else:
            print("  nothing was remembered")
        return 0

    staged = "--staged" in argv
    paths = staged_files() if staged else tracked_files()
    paths = [p for p in paths if interesting(p)]
    # Digests, not identifiers.
    disks = remembered_uuids(local_disk_uuids())
    mine = this_machine()

    findings = []
    for path in paths:
        text = contents(path, staged)
        if text:
            findings.extend(check(path, text, disks, mine))

    if not findings:
        where = "staged for commit" if staged else "tracked by git"
        print(f"  nothing of the owner's in the {len(paths)} files {where}")
        return 0

    print("")
    print("Something private is about to go into the repository:")
    print("")
    for path, line, what, value in findings:
        print(f"  {path}:{line}")
        print(f"      {what}: {value}")
    print("")
    print("Fixtures are invented, never captured. Use a made-up value, or add it")
    print("to ALLOWED in scripts/check-private.py if it is already one.")
    print("")
    print("Getting this into history costs a rewrite of every commit after it.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
