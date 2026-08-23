#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Wrap a raw disk image in a streamed VMDK, the monolithicStreamOptimized form.

    ./scripts/make-vmdk-streamed.py raw.img out.vmdk

The form a VMDK takes when it is written in one pass, as an export or down a
pipe: every grain is deflated and carries a marker saying which part of the
disk it holds, and the grain directory can only be placed once everything
before it has been written — so the header carries a placeholder and a copy of
it at the end of the file carries the true offset.

Written here rather than fetched, so the test has one to open without VMware or
qemu-img installed. A stream-optimized image is read and never written, and
Lukotta says so before opening one.
"""

import os
import struct
import sys
import zlib

SECTOR = 512
MAGIC = 0x564D444B  # KDMV
GRAIN = 128         # sectors, so 64 KB
GTES_PER_GT = 512
DESCRIPTOR_AT = 1   # sector
DESCRIPTOR_SECTORS = 20
NO_OFFSET_YET = 0xFFFFFFFFFFFFFFFF

# Bit 0 says the newline test is filled in, 16 that grains are deflated, 17
# that each one carries a marker. The last two only ever appear together.
FLAGS = 1 | (1 << 16) | (1 << 17)

MARKER_EOS = 0
MARKER_GRAIN_TABLE = 1
MARKER_GRAIN_DIRECTORY = 2
MARKER_FOOTER = 3


def header(capacity, gd_offset, overhead):
    head = bytearray(SECTOR)
    struct.pack_into("<I", head, 0, MAGIC)
    struct.pack_into("<I", head, 4, 3)                     # version
    struct.pack_into("<I", head, 8, FLAGS)
    struct.pack_into("<Q", head, 12, capacity)
    struct.pack_into("<Q", head, 20, GRAIN)
    struct.pack_into("<Q", head, 28, DESCRIPTOR_AT)
    struct.pack_into("<Q", head, 36, DESCRIPTOR_SECTORS)
    struct.pack_into("<I", head, 44, GTES_PER_GT)
    struct.pack_into("<Q", head, 48, 0)                    # no redundant directory
    struct.pack_into("<Q", head, 56, gd_offset)
    struct.pack_into("<Q", head, 64, overhead)
    head[72] = 0                                           # cleanly closed
    head[73:77] = b"\n \r\n"                               # newline detection
    struct.pack_into("<H", head, 77, 1)                    # deflate
    return bytes(head)


def marker(sectors, kind):
    """The 512-byte marker that announces a metadata region."""
    out = bytearray(SECTOR)
    struct.pack_into("<Q", out, 0, sectors)
    struct.pack_into("<I", out, 8, 0)
    struct.pack_into("<I", out, 12, kind)
    return bytes(out)


def write(source, destination):
    size = os.path.getsize(source)
    if size % (GRAIN * SECTOR):
        sys.exit("the raw image must be a whole number of 64 KB grains")
    capacity = size // SECTOR
    grains = capacity // GRAIN
    tables = (grains + GTES_PER_GT - 1) // GTES_PER_GT
    name = os.path.basename(destination)

    descriptor = (
        "# Disk DescriptorFile\n"
        "version=1\n"
        "CID=fffffffe\n"
        "parentCID=ffffffff\n"
        'createType="streamOptimized"\n'
        "\n"
        f'RW {capacity} SPARSE "{name}"\n'
        "\n"
        'ddb.adapterType = "lsilogic"\n'
        'ddb.geometry.heads = "16"\n'
        'ddb.geometry.sectors = "63"\n'
    ).encode()

    grain_tables = [[0] * GTES_PER_GT for _ in range(tables)]
    written = 0

    with open(source, "rb") as src, open(destination, "wb") as out:
        # The header goes down with a placeholder where the directory offset
        # will be. The copy at the end is what a reader believes.
        out.write(header(capacity, NO_OFFSET_YET, DESCRIPTOR_AT + DESCRIPTOR_SECTORS))
        out.write(descriptor.ljust(DESCRIPTOR_SECTORS * SECTOR, b"\x00"))

        for i in range(grains):
            chunk = src.read(GRAIN * SECTOR)
            # A grain of zeroes is left out, as in any sparse form.
            if not chunk.strip(b"\x00"):
                continue
            at = out.tell()
            assert at % SECTOR == 0
            grain_tables[i // GTES_PER_GT][i % GTES_PER_GT] = at // SECTOR
            deflated = zlib.compress(chunk, 9)
            # Marker and data together, padded to a whole number of sectors:
            # the sector this grain holds, how many bytes follow, then them.
            body = struct.pack("<QI", i * GRAIN, len(deflated)) + deflated
            out.write(body.ljust((len(body) + SECTOR - 1) // SECTOR * SECTOR, b"\x00"))
            written += 1

        # Each grain table, announced by its own marker.
        directory = []
        table_sectors = (GTES_PER_GT * 4 + SECTOR - 1) // SECTOR
        for table in grain_tables:
            out.write(marker(table_sectors, MARKER_GRAIN_TABLE))
            directory.append(out.tell() // SECTOR)
            packed = b"".join(struct.pack("<I", s) for s in table)
            out.write(packed.ljust(table_sectors * SECTOR, b"\x00"))

        directory_sectors = (tables * 4 + SECTOR - 1) // SECTOR
        out.write(marker(directory_sectors, MARKER_GRAIN_DIRECTORY))
        gd_offset = out.tell() // SECTOR
        packed = b"".join(struct.pack("<I", s) for s in directory)
        out.write(packed.ljust(directory_sectors * SECTOR, b"\x00"))

        # The footer: a copy of the header saying where the directory went,
        # then the end-of-stream marker. A reader takes the second sector from
        # the end, which is what this leaves there.
        out.write(marker(1, MARKER_FOOTER))
        out.write(header(capacity, gd_offset, DESCRIPTOR_AT + DESCRIPTOR_SECTORS))
        out.write(marker(0, MARKER_EOS))
    return size, grains, written


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    n, grains, count = write(sys.argv[1], sys.argv[2])
    print(f"{sys.argv[2]}: streamed VMDK of {n // (1024 * 1024)} MB, "
          f"{count}/{grains} grains deflated")
