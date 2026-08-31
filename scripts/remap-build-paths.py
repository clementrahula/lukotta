#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Keep the building machine out of the binaries the engine build produces.

rustc writes absolute source paths into panic messages and debug info, so a
plain build names wherever the crates happened to sit -- a home directory, and
with it an account name -- in something every user of the app installs.

The flag goes into each crate's own `.cargo/config.toml` rather than into
RUSTFLAGS, which replaces `target.*.rustflags` instead of adding to them: set
that way it takes vmproxy's cross-linker with it. Appending also survives
upstream changing its own flags.
"""
import os
import sys


def remapped(text, flag):
    """The same config with `flag` added to every rustflags array in it."""
    if flag in text:
        return text
    if "rustflags" not in text:
        # A target section would override [build], so this is only safe where
        # the file names no target flags at all -- which is why it is the
        # branch not taken whenever "rustflags" appears anywhere above.
        return text + "\n[build]\nrustflags = [%s]\n" % flag
    out, i = [], 0
    while True:
        j = text.find("rustflags", i)
        if j < 0:
            out.append(text[i:])
            return "".join(out)
        k = text.index("]", j)
        out.append(text[i:k])
        out.append("    %s,\n" % flag)
        i = k


def main():
    root, home = sys.argv[1], sys.argv[2]
    flag = '"--remap-path-prefix=%s=/build"' % home
    for base, _, files in os.walk(root):
        if os.path.basename(base) != ".cargo" or "config.toml" not in files:
            continue
        path = os.path.join(base, "config.toml")
        with open(path, encoding="utf-8") as f:
            text = f.read()
        fixed = remapped(text, flag)
        if fixed == text:
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(fixed)
        print("  path-remapped %s" % os.path.relpath(path, root))


if __name__ == "__main__":
    main()
