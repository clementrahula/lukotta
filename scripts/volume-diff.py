#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Say what changed between two copies of an NTFS volume, in NTFS's own terms.

A write to a filesystem is right when it changes exactly what it meant to and
nothing else, and that is a claim about four gigabytes rather than about the
bytes the writer happens to remember touching. So: diff the whole volume, merge
the differing bytes into regions, and name each one -- which record of the
master file table, which record of its mirror, or which cluster.

Deliberately independent of the Swift. It reads the boot sector and works out
the geometry from the on-disk format, so a mistake shared with the writer would
have to be made twice, in two languages, by reading the same specification the
same wrong way.

    scripts/volume-diff.py before.img after.img
"""

import struct
import sys

CHUNK = 1 << 20
# Runs closer together than this are reported as one region. A fixup signature
# and the sector copies it belongs to are the same edit, described once.
JOIN = 64


def geometry(boot):
    bytes_per_sector = struct.unpack_from("<H", boot, 0x0B)[0]
    sectors_per_cluster = boot[0x0D]
    if bytes_per_sector == 0 or sectors_per_cluster == 0:
        raise SystemExit("error: not an NTFS boot sector")
    cluster = bytes_per_sector * sectors_per_cluster
    per_record = struct.unpack_from("<b", boot, 0x40)[0]
    record = per_record * cluster if per_record > 0 else 1 << (-per_record)
    return {
        "sector": bytes_per_sector,
        "cluster": cluster,
        "record": record,
        "mft": struct.unpack_from("<Q", boot, 0x30)[0] * cluster,
        "mirror": struct.unpack_from("<Q", boot, 0x38)[0] * cluster,
    }


def regions(first, second):
    """Every stretch of bytes that differs, merged."""
    found = []
    offset = 0
    while True:
        left = first.read(CHUNK)
        right = second.read(CHUNK)
        if not left and not right:
            break
        if len(left) != len(right):
            print(f"note: the images are different lengths at {offset}", file=sys.stderr)
        length = min(len(left), len(right))
        index = 0
        while index < length:
            if left[index] == right[index]:
                index += 1
                continue
            end = index
            while end < length and left[end] != right[end]:
                end += 1
            if found and offset + index - found[-1][1] <= JOIN:
                found[-1][1] = offset + end
            else:
                found.append([offset + index, offset + end])
            index = end
        offset += length
        if len(left) < CHUNK and len(right) < CHUNK:
            break
    return found


def fixup(record, sector):
    """Put back the bytes NTFS displaced, so attributes can be walked."""
    data = bytearray(record)
    where = struct.unpack_from("<H", data, 4)[0]
    count = struct.unpack_from("<H", data, 6)[0]
    for index in range(1, count):
        end = index * sector - 2
        if end + 2 > len(data):
            break
        data[end : end + 2] = data[where + index * 2 : where + index * 2 + 2]
    return data


def mft_extents(f, g):
    """Where $MFT actually is.

    It is a file, and a file can be in pieces. Assuming it is contiguous names
    the wrong record for every byte past the first extent -- which is most of
    the table on a volume that has been used.
    """
    f.seek(g["mft"])
    record = fixup(f.read(g["record"]), g["sector"])
    if record[:4] != b"FILE":
        return [(g["mft"] // g["cluster"], 1 << 40)]
    offset = struct.unpack_from("<H", record, 0x14)[0]
    used = struct.unpack_from("<I", record, 0x18)[0]
    while offset < used:
        kind = struct.unpack_from("<I", record, offset)[0]
        if kind == 0xFFFFFFFF:
            break
        length = struct.unpack_from("<I", record, offset + 4)[0]
        if length == 0:
            break
        if kind == 0x80 and record[offset + 8]:
            at = offset + struct.unpack_from("<H", record, offset + 0x20)[0]
            runs, cluster = [], 0
            while record[at]:
                head = record[at]
                count_bytes, offset_bytes = head & 0xF, head >> 4
                at += 1
                span = int.from_bytes(record[at : at + count_bytes], "little")
                at += count_bytes
                cluster += int.from_bytes(
                    record[at : at + offset_bytes], "little", signed=True
                )
                at += offset_bytes
                runs.append((cluster, span))
            return runs
        offset += length
    return []


def describe(offset, g, mirrored_records, extents):
    per_cluster = g["cluster"] // g["record"]
    first = 0
    for cluster, span in extents:
        start = cluster * g["cluster"]
        if start <= offset < start + span * g["cluster"]:
            number = first + (offset - start) // g["record"]
            return f"$MFT record {number} +{(offset - start) % g['record']}"
        first += span * per_cluster
    if g["mirror"] <= offset < g["mirror"] + mirrored_records * g["record"]:
        number = (offset - g["mirror"]) // g["record"]
        return f"$MFTMirr record {number} +{(offset - g['mirror']) % g['record']}"
    if offset < g["cluster"]:
        return "the boot sector"
    return f"cluster {offset // g['cluster']}"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip().splitlines()[-1].strip())
    with open(sys.argv[1], "rb") as first, open(sys.argv[2], "rb") as second:
        g = geometry(first.read(512))
        extents = mft_extents(first, g)
        first.seek(0)
        found = regions(first, second)

    print(f"{len(found)} differing region(s):")
    total = 0
    for start, end in found:
        total += end - start
        print(f"  {start:>14}..{end:<14} {end - start:>7} bytes   {describe(start, g, 4, extents)}")
    print(f"{total} bytes in all")
    # Nothing is returned as a failure: what counts as too much depends on what
    # the write was meant to do, and that is the reader's judgement.


if __name__ == "__main__":
    main()
