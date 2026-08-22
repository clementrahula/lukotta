#!/usr/bin/env python3
"""Wrap a raw disk image in a VHDX.

    ./scripts/make-vhdx.py raw.img out.vhdx [--dirty | --parent]

The format has several structures: a file signature, two headers of which the
live one carries the higher sequence number, a region table locating the rest, a
metadata region giving the block and disk sizes, and an allocation table with one
entry per block.

`--dirty` writes one whose log is not empty, meaning it was not closed cleanly.
`--parent` writes one declaring that it holds only the changes from another disk.
The test checks that both are refused.
"""

import os
import struct
import sys
import uuid

MB = 1024 * 1024
BLOCK = 8 * MB
SECTOR = 512
HEADER_1, HEADER_2 = 0x10000, 0x20000
REGION_1, REGION_2 = 0x30000, 0x40000
LOG_AT, LOG_LENGTH = 1 * MB, 1 * MB
BAT_AT, BAT_LENGTH = 2 * MB, 1 * MB
META_AT, META_LENGTH = 3 * MB, 1 * MB
DATA_AT = 4 * MB

GUID_BAT = uuid.UUID("2dc27766-f623-4200-9d64-115e9bfd4a08")
GUID_METADATA = uuid.UUID("8b7ca206-4790-4b9a-b8fe-575f050f886e")
GUID_FILE_PARAMETERS = uuid.UUID("caa16737-fa36-4d43-b3b6-33f0aa44e76b")
GUID_VIRTUAL_DISK_SIZE = uuid.UUID("2fa54224-cd1b-4876-b211-5dbed83bf4b8")
GUID_LOGICAL_SECTOR_SIZE = uuid.UUID("8141bf1d-a96f-4709-ba47-f233a8faab5f")
GUID_PHYSICAL_SECTOR_SIZE = uuid.UUID("cda348c7-445d-4471-9cc9-e9885251c556")
GUID_PAGE_83 = uuid.UUID("beca12ab-b2e6-4523-93ef-c309e000c746")

BLOCK_NOT_PRESENT = 0
BLOCK_FULLY_PRESENT = 6


def crc32c(data):
    """The Castagnoli CRC, which is what VHDX checksums with."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def stamped(block):
    """Fill in the checksum a header or region table carries at offset 4."""
    block = bytearray(block)
    struct.pack_into("<I", block, 4, 0)
    struct.pack_into("<I", block, 4, crc32c(bytes(block)))
    return bytes(block)


def header(sequence, dirty):
    b = bytearray(4096)
    b[0:4] = b"head"
    struct.pack_into("<Q", b, 8, sequence)
    b[16:32] = uuid.uuid5(uuid.NAMESPACE_URL, "lukotta/file").bytes_le
    b[32:48] = uuid.uuid5(uuid.NAMESPACE_URL, "lukotta/data").bytes_le
    # Zero means the log holds nothing. Any other value marks an image that was
    # not closed cleanly, whose most recent state is still in the log.
    b[48:64] = uuid.uuid5(uuid.NAMESPACE_URL, "lukotta/log").bytes_le if dirty else bytes(16)
    struct.pack_into("<H", b, 64, 0)        # log version
    struct.pack_into("<H", b, 66, 1)        # version
    struct.pack_into("<I", b, 68, LOG_LENGTH)
    struct.pack_into("<Q", b, 72, LOG_AT)
    return stamped(b)


def region_table():
    b = bytearray(65536)
    b[0:4] = b"regi"
    struct.pack_into("<I", b, 8, 2)         # two regions
    for i, (guid, off, length) in enumerate(
        [(GUID_BAT, BAT_AT, BAT_LENGTH), (GUID_METADATA, META_AT, META_LENGTH)]
    ):
        at = 16 + i * 32
        b[at:at + 16] = guid.bytes_le
        struct.pack_into("<QII", b, at + 16, off, length, 1)  # required
    return stamped(b)


def metadata(size, parent):
    b = bytearray(META_LENGTH)
    b[0:8] = b"metadata"
    struct.pack_into("<H", b, 10, 5)        # entry count
    items = [
        (GUID_FILE_PARAMETERS, struct.pack("<II", BLOCK, 2 if parent else 0), 0b100),
        (GUID_VIRTUAL_DISK_SIZE, struct.pack("<Q", size), 0b110),
        (GUID_PAGE_83, uuid.uuid5(uuid.NAMESPACE_URL, "lukotta/page83").bytes_le, 0b110),
        (GUID_LOGICAL_SECTOR_SIZE, struct.pack("<I", SECTOR), 0b110),
        (GUID_PHYSICAL_SECTOR_SIZE, struct.pack("<I", 4096), 0b110),
    ]
    offset = 65536
    for i, (guid, value, flags) in enumerate(items):
        at = 32 + i * 32
        b[at:at + 16] = guid.bytes_le
        struct.pack_into("<III", b, at + 16, offset, len(value), flags)
        b[offset:offset + len(value)] = value
        offset += len(value)
    return bytes(b)


def write(source, destination, dirty=False, parent=False):
    size = os.path.getsize(source)
    blocks = (size + BLOCK - 1) // BLOCK
    # Every so many payload entries the table holds one describing a sector
    # bitmap, which only a differencing image uses. They are counted so that the
    # payload entries land where a reader expects them.
    chunk_ratio = (1 << 23) * SECTOR // BLOCK
    entries = blocks + (blocks - 1) // chunk_ratio

    bat = bytearray(BAT_LENGTH)
    with open(source, "rb") as src, open(destination, "wb") as out:
        out.write(b"vhdxfile" + "Lukotta".encode("utf-16-le").ljust(512 - 8, b"\x00"))
        out.seek(HEADER_1); out.write(header(1, dirty))
        out.seek(HEADER_2); out.write(header(2, dirty))
        out.seek(REGION_1); out.write(region_table())
        out.seek(REGION_2); out.write(region_table())
        out.seek(META_AT); out.write(metadata(size, parent))
        out.seek(LOG_AT); out.write(bytes(LOG_LENGTH))

        out.seek(DATA_AT)
        at = DATA_AT
        written = 0
        for i in range(blocks):
            chunk = src.read(BLOCK)
            index = i + i // chunk_ratio
            # A block of zeroes is left out of the file.
            if not chunk.strip(b"\x00"):
                struct.pack_into("<Q", bat, index * 8, BLOCK_NOT_PRESENT)
                continue
            struct.pack_into("<Q", bat, index * 8, at | BLOCK_FULLY_PRESENT)
            out.write(chunk + b"\x00" * (BLOCK - len(chunk)))
            at += BLOCK
            written += 1
        out.seek(BAT_AT); out.write(bat[: max(entries * 8, SECTOR)])
    return size, blocks, written


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    n, blocks, written = write(
        sys.argv[1], sys.argv[2],
        dirty="--dirty" in sys.argv, parent="--parent" in sys.argv)
    what = "dirty " if "--dirty" in sys.argv else "differencing " if "--parent" in sys.argv else ""
    print(f"{sys.argv[2]}: {what}VHDX of {n // MB} MB, {written}/{blocks} blocks written")
