#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Hash a file's real content, skipping the holes.

    sparse-digest.py <file>

Written because a corpus image turned out to be 233 GB long with 112 MB in it,
and `shasum` spent eight minutes reading a quarter of a terabyte of zeroes
before the harness holding it had produced a single result. Sparse test images
are normal -- an NTFS volume is mostly empty -- and a checksum that reads the
emptiness scales with the volume's declared size instead of its contents.

Only the data extents are hashed, and each is hashed together with its offset,
so a write that fills part of a hole changes the digest: the hole becomes data,
a new extent appears, and its offset goes in with its bytes. Length is folded
in too, so a truncation cannot pass.

SEEK_DATA and SEEK_HOLE are 4 and 3 on Darwin and on Linux. Where the
filesystem does not implement them the whole file reads as one extent, which is
correct and merely as slow as it was before.
"""
import hashlib, os, sys

SEEK_DATA, SEEK_HOLE = 4, 3
CHUNK = 8 << 20


def digest(path):
    h = hashlib.sha256()
    size = os.path.getsize(path)
    h.update(str(size).encode())
    fd = os.open(path, os.O_RDONLY)
    try:
        pos = 0
        while pos < size:
            try:
                start = os.lseek(fd, pos, SEEK_DATA)
            except OSError:
                start = pos          # no extent support: it is all data
            if start >= size:
                break
            try:
                end = os.lseek(fd, start, SEEK_HOLE)
            except OSError:
                end = size
            h.update(b"@" + str(start).encode())
            os.lseek(fd, start, os.SEEK_SET)
            left = end - start
            while left > 0:
                block = os.read(fd, min(CHUNK, left))
                if not block:
                    break
                h.update(block)
                left -= len(block)
            pos = end
    finally:
        os.close(fd)
    return h.hexdigest()


if __name__ == "__main__":
    print(digest(sys.argv[1]))
