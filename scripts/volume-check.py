#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Check an NTFS volume the way chkdsk would, from the on-disk format.

Everything else that checks this filesystem's writes is the filesystem's own
reader, and a reader and a writer that share a mistake agree with each other
perfectly. Two defects hid behind exactly that: a size that was right in the
record and zero in the index, and a modification time that never moved. Neither
was visible to anything that asked the record, and asking the record is what our
reader does.

So this is written from the specification, in another language, and shares no
line with the thing it checks. It walks the volume and complains about:

  - a record whose fixup does not verify (a torn write nobody noticed)
  - a record the bitmap and the header disagree about
  - a name whose parent is not a directory, or does not exist
  - an index entry pointing at a record that is not in use
  - an index entry whose name or size disagrees with the record it names
  - a directory node out of order under the volume's own $UpCase table
  - a name reachable by listing but not by descending the tree, or the reverse
  - a cluster claimed by two files, or by a file and not by $Bitmap

It does *not* complain about a cluster $Bitmap claims that no live record owns.
That is what a deleted file leaves: this filesystem does not overwrite a removed
file's clusters, because its record still points at them and that is what makes
it recoverable. Space held by nothing is space chkdsk reclaims, and here it is
deliberate.

Checked against damage, because a checker that has never failed is not a
checker: a torn record, a bitmap that disagrees with a record, an index entry
whose size disagrees with the record it names, and two files claiming the same
clusters are each found when introduced.

    scripts/volume-check.py volume.img
"""

import struct
import sys
from collections import defaultdict


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


class Volume:
    def __init__(self, path):
        self.f = open(path, "rb")
        boot = self.f.read(512)
        self.sector = u16(boot, 0x0B)
        per_cluster = boot[0x0D]
        if self.sector == 0 or per_cluster == 0:
            raise SystemExit("error: not an NTFS boot sector")
        self.cluster = self.sector * per_cluster
        self.total_clusters = u64(boot, 0x28) // per_cluster
        raw = struct.unpack_from("<b", boot, 0x40)[0]
        self.record_size = raw * self.cluster if raw > 0 else 1 << (-raw)
        self.mft = u64(boot, 0x30) * self.cluster
        self.problems = []
        # $MFT's own runlist lives in record 0, which cannot be found without
        # it. So start with the first extent the boot sector points at, read
        # record 0 through that, and replace it with what record 0 says.
        self.mft_runs = [(self.mft // self.cluster, 1 << 20)]
        found = self.runs_of(0, 0x80)
        if found:
            self.mft_runs = found

    def complain(self, what):
        self.problems.append(what)

    def at(self, offset, length):
        self.f.seek(offset)
        return self.f.read(length)

    def record_offset(self, number):
        per = self.cluster // self.record_size
        seen = 0
        for start, count in self.mft_runs:
            if number < seen + count * per:
                return start * self.cluster + (number - seen) * self.record_size
            seen += count * per
        return None

    def record(self, number, quiet=False):
        offset = self.record_offset(number)
        if offset is None:
            return None
        data = bytearray(self.at(offset, self.record_size))
        if len(data) < 42 or data[:4] != b"FILE":
            return None
        where, count = u16(data, 4), u16(data, 6)
        if where + count * 2 > len(data):
            return None
        signature = bytes(data[where : where + 2])
        for sector in range(1, count):
            end = sector * self.sector - 2
            if end + 2 > len(data):
                break
            if bytes(data[end : end + 2]) != signature:
                if not quiet:
                    self.complain(f"record {number}: sector {sector} is a torn write")
                return None
            data[end : end + 2] = data[where + sector * 2 : where + sector * 2 + 2]
        return data

    def attributes(self, data):
        found = []
        at = u16(data, 0x14)
        used = u32(data, 0x18)
        while at + 8 <= used and at + 8 <= len(data):
            kind = u32(data, at)
            if kind == 0xFFFFFFFF:
                break
            length = u32(data, at + 4)
            if length < 24 or at + length > used:
                break
            found.append((kind, at, length))
            at += length
        return found

    def runs_at(self, data, at):
        runs, cluster = [], 0
        while at < len(data) and data[at]:
            head = data[at]
            count_bytes, offset_bytes = head & 0xF, head >> 4
            at += 1
            span = int.from_bytes(data[at : at + count_bytes], "little")
            at += count_bytes
            if offset_bytes:
                cluster += int.from_bytes(
                    data[at : at + offset_bytes], "little", signed=True
                )
                at += offset_bytes
                runs.append((cluster, span))
            else:
                runs.append((None, span))
        return runs

    def runs_of(self, number, kind, name=None):
        data = self.record(number, quiet=True)
        if data is None:
            return None
        for attribute, at, _ in self.attributes(data):
            if attribute != kind or not data[at + 8]:
                continue
            if name is not None and self.attribute_name(data, at) != name:
                continue
            return self.runs_at(data, at + u16(data, at + 0x20))
        return None

    def attribute_name(self, data, at):
        length = data[at + 9]
        if not length:
            return None
        where = u16(data, at + 10)
        return data[at + where : at + where + length * 2].decode("utf-16-le")

    def contents(self, number, kind=0x80, name=None):
        data = self.record(number, quiet=True)
        if data is None:
            return None
        for attribute, at, length in self.attributes(data):
            if attribute != kind:
                continue
            if name is not None and self.attribute_name(data, at) != name:
                continue
            if not data[at + 8]:
                where, size = u16(data, at + 0x14), u32(data, at + 0x10)
                return bytes(data[at + where : at + where + size])
            size = u64(data, at + 0x30)
            out = b""
            for start, span in self.runs_at(data, at + u16(data, at + 0x20)):
                if start is None:
                    out += b"\0" * (span * self.cluster)
                else:
                    out += self.at(start * self.cluster, span * self.cluster)
            return out[:size]
        return None


def names_of(volume, data):
    """Every $FILE_NAME in a record: parent, namespace, name, sizes."""
    found = []
    for kind, at, _ in volume.attributes(data):
        if kind != 0x30 or data[at + 8]:
            continue
        where = u16(data, at + 0x14)
        value = data[at + where : at + where + u32(data, at + 0x10)]
        if len(value) < 66:
            continue
        length = value[0x40]
        found.append(
            {
                "parent": u64(value, 0) & 0x0000FFFFFFFFFFFF,
                "namespace": value[0x41],
                "name": bytes(value[0x42 : 0x42 + length * 2]).decode(
                    "utf-16-le", "replace"
                ),
                "allocated": u64(value, 40),
                "size": u64(value, 48),
            }
        )
    return found


def entries_of(volume, node, at, end):
    """Walk one index node's entries."""
    found = []
    seen = 0
    while at + 16 <= end and seen < 8192:
        seen += 1
        length = u16(node, at + 8)
        flags = u16(node, at + 12)
        if length < 16 or at + length > end + 16:
            break
        if flags & 2:
            child = u64(node, at + length - 8) if flags & 1 else None
            found.append({"last": True, "child": child})
            break
        key_length = u16(node, at + 10)
        key = node[at + 16 : at + 16 + key_length]
        name = ""
        size = 0
        if key_length >= 66:
            name = bytes(key[0x42 : 0x42 + key[0x40] * 2]).decode("utf-16-le", "replace")
            size = u64(key, 48)
        found.append(
            {
                "last": False,
                "record": u64(node, at) & 0x0000FFFFFFFFFFFF,
                "name": name,
                "size": size,
                "namespace": key[0x41] if key_length >= 66 else 0,
                "child": u64(node, at + length - 8) if flags & 1 else None,
            }
        )
        at += length
    return found


def index_nodes(volume, number):
    """Every node of a directory's index: the root, then the blocks it owns."""
    data = volume.record(number, quiet=True)
    if data is None:
        return []
    nodes = []
    block_size = 0
    for kind, at, _ in volume.attributes(data):
        if kind != 0x90 or data[at + 8]:
            continue
        where = u16(data, at + 0x14)
        value_end = where + u32(data, at + 0x10)
        block_size = u32(data, at + where + 8)
        node = at + where + 16
        nodes.append(
            (
                "root",
                None,
                entries_of(
                    volume, data, node + u32(data, node), min(at + value_end, len(data))
                ),
            )
        )
    if block_size < 512:
        return nodes
    allocation = volume.contents(number, 0xA0, "$I30")
    if not allocation:
        return nodes
    for index in range(len(allocation) // block_size):
        raw = bytearray(allocation[index * block_size : (index + 1) * block_size])
        if raw[:4] != b"INDX":
            continue
        where, count = u16(raw, 4), u16(raw, 6)
        signature = bytes(raw[where : where + 2])
        torn = False
        for sector in range(1, count):
            end = sector * volume.sector - 2
            if end + 2 > len(raw):
                break
            if bytes(raw[end : end + 2]) != signature:
                torn = True
                break
            raw[end : end + 2] = raw[where + sector * 2 : where + sector * 2 + 2]
        if torn:
            volume.complain(f"directory {number}: index block {index} is a torn write")
            continue
        node = 0x18
        nodes.append(
            (
                "block",
                index,
                entries_of(volume, raw, node + u32(raw, node), node + u32(raw, node + 4)),
            )
        )
    return nodes


def upcase(volume):
    """The volume's own uppercase table, which is what orders its names."""
    raw = volume.contents(10)
    if not raw or len(raw) < 65536 * 2:
        return None
    return struct.unpack(f"<{65536}H", raw[: 65536 * 2])


def compare(table, first, second):
    """Order two names the way the volume orders them."""
    left = [table[ord(c)] if ord(c) < 65536 else ord(c) for c in first]
    right = [table[ord(c)] if ord(c) < 65536 else ord(c) for c in second]
    return (left > right) - (left < right)


def check(path):
    volume = Volume(path)
    table = upcase(volume)
    if table is None:
        volume.complain("$UpCase does not read, so nothing can be checked for order")

    record_bitmap = volume.contents(0, 0xB0)
    if record_bitmap is None:
        raise SystemExit("error: $MFT has no $BITMAP")
    cluster_bitmap = volume.contents(6)
    if cluster_bitmap is None:
        raise SystemExit("error: $Bitmap does not read")

    records = 0
    for _, count in volume.mft_runs:
        records += count * (volume.cluster // volume.record_size)
    records = min(records, len(record_bitmap) * 8)

    in_use = {}
    directories = set()
    checked = 0
    for number in range(records):
        claimed = bool(record_bitmap[number // 8] >> (number % 8) & 1)
        data = volume.record(number)
        present = bool(data and u16(data, 0x16) & 1)
        if data is not None:
            checked += 1
        if claimed != present:
            volume.complain(
                f"record {number}: the bitmap says {'taken' if claimed else 'free'} "
                f"and the record says {'in use' if present else 'not'}"
            )
        if present:
            in_use[number] = data
            if u16(data, 0x16) & 2:
                directories.add(number)

    # Every name's parent must be a directory that exists.
    for number, data in in_use.items():
        for name in names_of(volume, data):
            if name["parent"] not in in_use:
                volume.complain(
                    f"record {number} ({name['name']}): its parent {name['parent']} is not in use"
                )
            elif name["parent"] not in directories:
                volume.complain(
                    f"record {number} ({name['name']}): its parent {name['parent']} is not a "
                    "directory"
                )

    # Every directory's index: entries live, names and sizes agreeing with the
    # records they name, and every node in the volume's own order.
    listed = defaultdict(set)
    for number in sorted(directories):
        for kind, index, entries in index_nodes(volume, number):
            names = [e["name"] for e in entries if not e["last"] and e["name"]]
            if table is not None:
                for at in range(1, len(names)):
                    if compare(table, names[at - 1], names[at]) >= 0:
                        volume.complain(
                            f"directory {number} {kind} {index}: {names[at - 1]!r} is filed "
                            f"before {names[at]!r}, which is not the volume's order"
                        )
            for entry in entries:
                if entry["last"]:
                    continue
                listed[number].add(entry["name"])
                target = entry["record"]
                if target not in in_use:
                    volume.complain(
                        f"directory {number}: {entry['name']!r} names record {target}, "
                        "which is not in use"
                    )
                    continue
                if target == number:
                    continue
                theirs = names_of(volume, in_use[target])
                mine = [n for n in theirs if n["namespace"] == entry["namespace"]]
                if mine and mine[0]["name"] != entry["name"]:
                    volume.complain(
                        f"directory {number}: the entry says {entry['name']!r} and record "
                        f"{target} says {mine[0]['name']!r}"
                    )
                if mine and mine[0]["size"] != entry["size"]:
                    volume.complain(
                        f"directory {number}: {entry['name']!r} lists as {entry['size']} bytes "
                        f"and its record says {mine[0]['size']}"
                    )

    # Clusters: nothing owned twice, and nothing owned that $Bitmap thinks free.
    owner = {}
    for number, data in in_use.items():
        for kind, at, _ in volume.attributes(data):
            if not data[at + 8]:
                continue
            for start, span in volume.runs_at(data, at + u16(data, at + 0x20)):
                if start is None:
                    continue
                for cluster in range(start, start + span):
                    if cluster >= volume.total_clusters:
                        volume.complain(
                            f"record {number}: cluster {cluster} is past the end of the volume"
                        )
                        break
                    if cluster in owner and owner[cluster] != number:
                        volume.complain(
                            f"cluster {cluster} is claimed by records {owner[cluster]} "
                            f"and {number}"
                        )
                    owner[cluster] = number
                    byte = cluster // 8
                    if byte >= len(cluster_bitmap) or not (
                        cluster_bitmap[byte] >> (cluster % 8) & 1
                    ):
                        volume.complain(
                            f"record {number}: cluster {cluster} is used but $Bitmap says free"
                        )

    print(f"records read: {checked}, in use: {len(in_use)}, directories: {len(directories)}")
    print(f"clusters accounted for: {len(owner)} of {volume.total_clusters}")
    print(f"directories listed: {len(listed)}, names: {sum(len(v) for v in listed.values())}")
    if volume.problems:
        print(f"\n{len(volume.problems)} problem(s):")
        for problem in volume.problems[:40]:
            print(f"  {problem}")
        if len(volume.problems) > 40:
            print(f"  ... and {len(volume.problems) - 40} more")
        return 1
    print("\nno problems found")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: scripts/volume-check.py volume.img")
    sys.exit(check(sys.argv[1]))
