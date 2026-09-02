#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Wrap a raw disk image in a qcow2 container.

There is no qemu-img on a Mac by default and none in the guest, so the
end-to-end test writes its own qcow2. The mapping is linear, every guest cluster
pointing at the next host cluster, which is the simplest valid qcow2 and what a
converted image looks like.

    ./scripts/make-qcow2.py raw.img out.qcow2
"""

import struct
import sys

CLUSTER_BITS = 16
CLUSTER = 1 << CLUSTER_BITS
REFCOUNT_ORDER = 4  # 16-bit refcounts
L2_ENTRIES = CLUSTER // 8
REFCOUNTS_PER_BLOCK = CLUSTER * 8 // (1 << REFCOUNT_ORDER)


def hostile(destination, backing=None, external=False, corrupt=False):
    """Write a qcow2 that names another file, for the tests that refuse one."""
    image = bytearray(CLUSTER * 3)
    image[0:4] = b"QFI\xfb"
    struct.pack_into(">I", image, 4, 3)
    struct.pack_into(">I", image, 20, CLUSTER_BITS)
    struct.pack_into(">Q", image, 24, CLUSTER)
    struct.pack_into(">I", image, 96, REFCOUNT_ORDER)
    struct.pack_into(">I", image, 100, 104)
    features = 0
    if external:
        features |= 1 << 2
    if corrupt:
        features |= 1 << 1
    struct.pack_into(">Q", image, 72, features)
    if backing:
        name = backing.encode()
        struct.pack_into(">Q", image, 8, 512)
        struct.pack_into(">I", image, 16, len(name))
        image[512:512 + len(name)] = name
    with open(destination, "wb") as f:
        f.write(image)
    return destination


def main(source, destination):
    with open(source, "rb") as f:
        data = f.read()
    virtual = (len(data) + CLUSTER - 1) // CLUSTER * CLUSTER
    clusters = virtual // CLUSTER

    l2_tables = (clusters + L2_ENTRIES - 1) // L2_ENTRIES
    # 0 header, 1 refcount table, then the refcount blocks, then L1, the L2s,
    # and the data.
    #
    # There used to be exactly one refcount block, which put a ceiling of two
    # gibibytes on anything this could write -- and the sweep that uses it needs
    # more than that, because the corpus carries a sparse file that arrives at
    # its apparent size. Raising the sweep's image size therefore did not widen
    # the coverage, it removed qcow2 from it.
    #
    # How many blocks are needed depends on the total, which depends on how many
    # blocks there are, so it settles rather than being calculated: one more
    # block pushes everything after it along by one cluster, which can need one
    # more block. It converges in two passes on any real size, and the loop is
    # bounded regardless.
    refcount_table_at = 1
    refcount_blocks = 1
    for _ in range(64):
        refcount_block_at = 2
        l1_at = refcount_block_at + refcount_blocks
        l2_at = l1_at + 1
        data_at = l2_at + l2_tables
        total = data_at + clusters
        needed = (total + REFCOUNTS_PER_BLOCK - 1) // REFCOUNTS_PER_BLOCK
        if needed == refcount_blocks:
            break
        refcount_blocks = needed
    else:
        sys.exit("the refcount block count would not settle")
    # The table itself is one cluster, which holds this many entries.
    if refcount_blocks > CLUSTER // 8:
        sys.exit("image too large for a one-cluster refcount table")

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

    # Refcount table: one entry per block, in order.
    for i in range(refcount_blocks):
        struct.pack_into(
            ">Q", image, refcount_table_at * CLUSTER + i * 8,
            (refcount_block_at + i) * CLUSTER)

    # Every cluster this file uses is referenced exactly once, in whichever
    # block covers it.
    for cluster in range(total):
        block, index = divmod(cluster, REFCOUNTS_PER_BLOCK)
        struct.pack_into(
            ">H", image, (refcount_block_at + block) * CLUSTER + index * 2, 1)

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
    if len(sys.argv) == 4 and sys.argv[1] == "--hostile":
        print(hostile(sys.argv[2], backing=sys.argv[3]))
    elif len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
