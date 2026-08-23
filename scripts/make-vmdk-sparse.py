#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Wrap a raw disk image in a sparse VMDK, the monolithicSparse form.

    ./scripts/make-vmdk-sparse.py raw.img out.vmdk

One file holding the header, the text descriptor that a flat VMDK keeps
separately, a grain directory, the grain tables and the grains, one for each
64 KB of disk written to. A grain of zeroes is left out, which keeps the file
small.

Written here rather than fetched, so that the test has one to open without
VMware or qemu-img installed.
"""

import os
import struct
import sys

SECTOR = 512
MAGIC = 0x564D444B  # KDMV
GRAIN = 128         # sectors, so 64 KB
GTES_PER_GT = 512
DESCRIPTOR_AT = 1   # sector
DESCRIPTOR_SECTORS = 20


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
        'createType="monolithicSparse"\n'
        "\n"
        f'RW {capacity} SPARSE "{name}"\n'
        "\n"
        'ddb.adapterType = "lsilogic"\n'
        'ddb.geometry.heads = "16"\n'
        'ddb.geometry.sectors = "63"\n'
    ).encode()

    gd_at = DESCRIPTOR_AT + DESCRIPTOR_SECTORS
    gd_sectors = (tables * 4 + SECTOR - 1) // SECTOR
    gt_at = gd_at + gd_sectors
    gt_sectors = (GTES_PER_GT * 4 + SECTOR - 1) // SECTOR
    data_at = gt_at + gt_sectors * tables

    header = bytearray(SECTOR)
    struct.pack_into("<I", header, 0, MAGIC)
    struct.pack_into("<I", header, 4, 1)                   # version
    struct.pack_into("<I", header, 8, 3)                   # newline check + rgd
    struct.pack_into("<Q", header, 12, capacity)
    struct.pack_into("<Q", header, 20, GRAIN)
    struct.pack_into("<Q", header, 28, DESCRIPTOR_AT)
    struct.pack_into("<Q", header, 36, DESCRIPTOR_SECTORS)
    struct.pack_into("<I", header, 44, GTES_PER_GT)
    struct.pack_into("<Q", header, 48, 0)                  # no redundant directory
    struct.pack_into("<Q", header, 56, gd_at)
    struct.pack_into("<Q", header, 64, data_at)            # overhead
    header[72] = 0                                         # cleanly closed
    header[73:77] = b"\n \r\n"                             # newline detection
    struct.pack_into("<H", header, 77, 0)                  # not compressed

    directory = [0] * tables
    grain_tables = [[0] * GTES_PER_GT for _ in range(tables)]

    with open(source, "rb") as src, open(destination, "wb") as out:
        out.write(header)
        out.write(descriptor.ljust(DESCRIPTOR_SECTORS * SECTOR, b"\x00"))
        for i in range(tables):
            directory[i] = gt_at + i * gt_sectors
        out.write(b"".join(struct.pack("<I", s) for s in directory)
                  .ljust(gd_sectors * SECTOR, b"\x00"))
        out.seek(data_at * SECTOR)

        sector = data_at
        written = 0
        for i in range(grains):
            chunk = src.read(GRAIN * SECTOR)
            # A grain of zeroes is left out of the file.
            if not chunk.strip(b"\x00"):
                continue
            grain_tables[i // GTES_PER_GT][i % GTES_PER_GT] = sector
            out.write(chunk)
            sector += GRAIN
            written += 1

        for i, table in enumerate(grain_tables):
            out.seek(directory[i] * SECTOR)
            out.write(b"".join(struct.pack("<I", s) for s in table))
    return size, grains, written


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    n, grains, written = write(sys.argv[1], sys.argv[2])
    print(f"{sys.argv[2]}: sparse VMDK of {n // (1024 * 1024)} MB, "
          f"{written}/{grains} grains written")
