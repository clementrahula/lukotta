#!/usr/bin/env python3
"""Wrap a raw disk image in a VHD.

    ./scripts/make-vhd.py raw.img out.vhd [--dynamic]

A fixed VHD is the raw disk followed by a 512-byte footer, which is why the
engine opens one with no format support at all. The dynamic form is written too,
so the test has something that must be refused rather than mounted as gibberish.
"""

import os
import struct
import sys

FOOTER = 512


def footer(size, kind, data_offset=0xFFFFFFFFFFFFFFFF):
    f = bytearray(FOOTER)
    f[0:8] = b"conectix"
    struct.pack_into(">I", f, 8, 2)                  # features
    struct.pack_into(">I", f, 12, 0x00010000)        # format version
    struct.pack_into(">Q", f, 16, data_offset)
    f[28:32] = b"lkta"
    struct.pack_into(">I", f, 32, 0x00010000)
    f[36:40] = b"Mac "
    struct.pack_into(">Q", f, 40, size)              # original size
    struct.pack_into(">Q", f, 48, size)              # current size
    struct.pack_into(">H", f, 56, min(65535, size // 512 // (16 * 63)))
    f[58] = 16
    f[59] = 63
    struct.pack_into(">I", f, 60, kind)
    f[68:84] = bytes(range(16))                      # unique id
    struct.pack_into(">I", f, 64, (~sum(f)) & 0xFFFFFFFF)
    return bytes(f)


def fixed(source, destination):
    size = os.path.getsize(source)
    with open(source, "rb") as src, open(destination, "wb") as out:
        while chunk := src.read(1 << 20):
            out.write(chunk)
        out.write(footer(size, 2))
    return size


def dynamic(source, destination):
    """A dynamic VHD, block by block. Only what is needed to be a real one."""
    block = 2 * 1024 * 1024
    size = os.path.getsize(source)
    blocks = (size + block - 1) // block
    bitmap = 512  # one sector of bitmap before each block's data

    # footer copy | dynamic header | BAT | blocks...
    bat_at = FOOTER + 1024
    bat_size = (blocks * 4 + 511) // 512 * 512
    data_at = bat_at + bat_size

    head = bytearray(1024)
    head[0:8] = b"cxsparse"
    struct.pack_into(">Q", head, 8, 0xFFFFFFFFFFFFFFFF)  # next offset: none
    struct.pack_into(">Q", head, 16, bat_at)
    struct.pack_into(">I", head, 24, 0x00010000)
    struct.pack_into(">I", head, 28, blocks)
    struct.pack_into(">I", head, 32, block)
    struct.pack_into(">I", head, 36, (~sum(head)) & 0xFFFFFFFF)

    bat = bytearray(b"\xff" * bat_size)
    with open(source, "rb") as src, open(destination, "wb") as out:
        out.write(footer(size, 3, data_offset=FOOTER))
        out.write(head)
        out.write(bat)                                # rewritten at the end
        sector = data_at // 512
        for i in range(blocks):
            struct.pack_into(">I", bat, i * 4, sector)
            out.write(b"\xff" * bitmap)               # every sector present
            chunk = src.read(block)
            out.write(chunk + b"\x00" * (block - len(chunk)))
            sector += (bitmap + block) // 512
        out.write(footer(size, 3, data_offset=FOOTER))
        out.seek(bat_at)
        out.write(bat)
    return size


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if "--dynamic" in sys.argv:
        n = dynamic(sys.argv[1], sys.argv[2])
        print(f"{sys.argv[2]}: dynamic VHD of {n // (1024 * 1024)} MB")
    else:
        n = fixed(sys.argv[1], sys.argv[2])
        print(f"{sys.argv[2]}: fixed VHD of {n // (1024 * 1024)} MB")
