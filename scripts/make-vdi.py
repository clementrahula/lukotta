#!/usr/bin/env python3
"""Wrap a raw disk image in a VDI, VirtualBox's format.

    ./scripts/make-vdi.py raw.img out.vdi

A VDI is a header, a block map, and then the blocks. The map has one 32-bit
entry per block of the virtual disk holding that block's index in the file;
0xffffffff means the block was never written and reads as zeroes, which is how a
mostly-empty disk stays small.

Written here rather than fetched so the test has a VDI to open without anyone
needing VirtualBox or qemu-img installed.
"""

import os
import struct
import sys

SIGNATURE = 0xBEDA107F
BLOCK = 1024 * 1024
FREE = 0xFFFFFFFF
HEADER = 0x200


def write(source, destination):
    size = os.path.getsize(source)
    blocks = (size + BLOCK - 1) // BLOCK
    map_at = HEADER
    map_bytes = (blocks * 4 + 511) // 512 * 512
    data_at = map_at + map_bytes

    header = bytearray(HEADER)
    header[0:64] = b"<<< Lukotta test disk image >>>\n".ljust(64, b"\x00")
    struct.pack_into("<I", header, 0x40, SIGNATURE)
    struct.pack_into("<I", header, 0x44, 0x00010001)  # version 1.1
    struct.pack_into("<I", header, 0x48, 0x190)       # header size
    struct.pack_into("<I", header, 0x4C, 1)           # dynamic
    struct.pack_into("<I", header, 0x154, map_at)
    struct.pack_into("<I", header, 0x158, data_at)
    struct.pack_into("<I", header, 0x160, 255)        # heads
    struct.pack_into("<I", header, 0x164, 63)         # sectors
    struct.pack_into("<I", header, 0x168, 512)        # sector size
    struct.pack_into("<Q", header, 0x170, size)
    struct.pack_into("<I", header, 0x178, BLOCK)
    struct.pack_into("<I", header, 0x17C, 0)          # no padding per block
    struct.pack_into("<I", header, 0x180, blocks)

    block_map = bytearray(b"\xff" * map_bytes)
    allocated = 0
    with open(source, "rb") as src, open(destination, "wb") as out:
        out.write(header)
        out.write(block_map)                          # rewritten at the end
        for i in range(blocks):
            chunk = src.read(BLOCK)
            # A block of nothing is left out of the file entirely, which is
            # what keeps a mostly-empty disk small.
            if not chunk.strip(b"\x00"):
                continue
            struct.pack_into("<I", block_map, i * 4, allocated)
            out.write(chunk + b"\x00" * (BLOCK - len(chunk)))
            allocated += 1
        struct.pack_into("<I", header, 0x184, allocated)
        out.seek(0)
        out.write(header)
        out.write(block_map)
    return size, blocks, allocated


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    n, blocks, allocated = write(sys.argv[1], sys.argv[2])
    print(f"{sys.argv[2]}: VDI of {n // (1024 * 1024)} MB, {allocated}/{blocks} blocks written")
