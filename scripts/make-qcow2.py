#!/usr/bin/env python3
"""Wrap a raw disk image in a qcow2 container.

There is no qemu-img on a Mac by default and the guest has none either, so the
end-to-end test builds its own qcow2 rather than going without one. The mapping
is linear — every guest cluster points at the next host cluster — which is the
simplest valid qcow2 there is and exactly what a converted image looks like.

    ./scripts/make-qcow2.py raw.img out.qcow2
"""

import struct
import sys

CLUSTER_BITS = 16
CLUSTER = 1 << CLUSTER_BITS
REFCOUNT_ORDER = 4  # 16-bit refcounts
L2_ENTRIES = CLUSTER // 8
REFCOUNTS_PER_BLOCK = CLUSTER * 8 // (1 << REFCOUNT_ORDER)


def main(source, destination):
    with open(source, "rb") as f:
        data = f.read()
    virtual = (len(data) + CLUSTER - 1) // CLUSTER * CLUSTER
    clusters = virtual // CLUSTER

    l2_tables = (clusters + L2_ENTRIES - 1) // L2_ENTRIES
    # 0 header, 1 refcount table, 2 refcount block, 3 L1, then the L2s, then data.
    refcount_table_at = 1
    refcount_block_at = 2
    l1_at = 3
    l2_at = 4
    data_at = l2_at + l2_tables
    total = data_at + clusters
    if total > REFCOUNTS_PER_BLOCK:
        sys.exit("image too large for this deliberately simple writer")

    image = bytearray(total * CLUSTER)

    # Header: qcow2 version 3, written field by field.
    image[0:4] = b"QFI\xfb"
    struct.pack_into(">I", image, 4, 3)                        # version
    struct.pack_into(">Q", image, 8, 0)                        # backing file offset
    struct.pack_into(">I", image, 16, 0)                       # backing file size
    struct.pack_into(">I", image, 20, CLUSTER_BITS)            # cluster bits
    struct.pack_into(">Q", image, 24, virtual)                 # size
    struct.pack_into(">I", image, 32, 0)                       # crypt method
    struct.pack_into(">I", image, 36, l2_tables)               # L1 size
    struct.pack_into(">Q", image, 40, l1_at * CLUSTER)         # L1 table offset
    struct.pack_into(">Q", image, 48, refcount_table_at * CLUSTER)
    struct.pack_into(">I", image, 56, 1)                       # refcount table clusters
    struct.pack_into(">I", image, 60, 0)                       # nb snapshots
    struct.pack_into(">Q", image, 64, 0)                       # snapshots offset
    struct.pack_into(">Q", image, 72, 0)                       # incompatible features
    struct.pack_into(">Q", image, 80, 0)                       # compatible features
    struct.pack_into(">Q", image, 88, 0)                       # autoclear features
    struct.pack_into(">I", image, 96, REFCOUNT_ORDER)
    struct.pack_into(">I", image, 100, 104)                    # header length

    # Refcount table: one entry, pointing at the single refcount block.
    struct.pack_into(">Q", image, refcount_table_at * CLUSTER, refcount_block_at * CLUSTER)

    # Every cluster this file uses is referenced exactly once.
    for cluster in range(total):
        struct.pack_into(">H", image, refcount_block_at * CLUSTER + cluster * 2, 1)

    # L1 entries point at the L2 tables; bit 63 marks them allocated.
    for i in range(l2_tables):
        struct.pack_into(
            ">Q", image, l1_at * CLUSTER + i * 8, ((l2_at + i) * CLUSTER) | (1 << 63))

    # L2 entries map each guest cluster to its host cluster, in order.
    for guest in range(clusters):
        table, index = divmod(guest, L2_ENTRIES)
        struct.pack_into(
            ">Q", image, (l2_at + table) * CLUSTER + index * 8,
            ((data_at + guest) * CLUSTER) | (1 << 63))

    image[data_at * CLUSTER:data_at * CLUSTER + len(data)] = data

    with open(destination, "wb") as f:
        f.write(image)
    print(f"{destination}: {virtual // (1024 * 1024)} MB in {total} clusters")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
