#!/usr/bin/env python3
"""Write a GPT with a single partition into a raw image file.

macOS can only do this with root, and the guest's busybox fdisk has no GPT
support, so the test fixtures would otherwise need a password to build. The
format is stable and small enough to write directly, which keeps the whole
fixture suite runnable by an ordinary user.
"""
import argparse, binascii, struct, uuid

SECTOR = 512
ENTRIES = 128
ENTRY_SIZE = 128

TYPES = {
    "linux-lvm": "E6D6D379-F507-44C2-A23C-238F2A3DF928",
    "linux-filesystem": "0FC63DAF-8483-4772-8E79-3D69D8477DE4",
    "microsoft-basic-data": "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
}


def guid_bytes(text):
    """GPT stores the first three GUID fields little-endian, the rest as-is."""
    return uuid.UUID(text).bytes_le


def header(current, backup, first_usable, last_usable, disk_guid, entries_lba, entries_crc):
    fields = struct.pack(
        "<8sIIIIQQQQ16sQIII",
        b"EFI PART", 0x00010000, 92, 0, 0,
        current, backup, first_usable, last_usable,
        disk_guid, entries_lba, ENTRIES, ENTRY_SIZE, entries_crc)
    crc = binascii.crc32(fields) & 0xFFFFFFFF
    return fields[:16] + struct.pack("<I", crc) + fields[20:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--megabytes", type=int, required=True)
    ap.add_argument("--type", default="linux-lvm", choices=sorted(TYPES))
    ap.add_argument("--name", default="lukotta-test")
    args = ap.parse_args()

    total = args.megabytes * 1024 * 1024 // SECTOR
    entry_sectors = ENTRIES * ENTRY_SIZE // SECTOR
    first_usable = 2 + entry_sectors
    last_usable = total - 2 - entry_sectors
    # Align the payload to 1 MiB, as every partitioner does.
    first = max(first_usable, 2048)

    entry = (
        guid_bytes(TYPES[args.type])
        + uuid.uuid4().bytes_le
        + struct.pack("<QQQ", first, last_usable, 0)
        + args.name.encode("utf-16-le").ljust(72, b"\0")[:72])
    table = entry + b"\0" * (ENTRIES * ENTRY_SIZE - len(entry))
    table_crc = binascii.crc32(table) & 0xFFFFFFFF
    disk_guid = uuid.uuid4().bytes_le

    with open(args.image, "r+b") as f:
        f.truncate(total * SECTOR)

        # Protective MBR: one 0xEE partition covering the disk, so tools that
        # only understand MBR see it as in use rather than as empty.
        mbr = bytearray(SECTOR)
        mbr[446:462] = struct.pack(
            "<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1,
            min(total - 1, 0xFFFFFFFF))
        mbr[510:512] = b"\x55\xAA"
        f.seek(0)
        f.write(bytes(mbr))

        f.seek(1 * SECTOR)
        f.write(header(1, total - 1, first_usable, last_usable, disk_guid, 2, table_crc))
        f.seek(2 * SECTOR)
        f.write(table)

        # The backup copies live at the very end, entries first.
        f.seek((total - 1 - entry_sectors) * SECTOR)
        f.write(table)
        f.seek((total - 1) * SECTOR)
        f.write(header(
            total - 1, 1, first_usable, last_usable, disk_guid,
            total - 1 - entry_sectors, table_crc))

    print(f"{args.image}: GPT with one {args.type} partition, sectors {first}-{last_usable}")


if __name__ == "__main__":
    main()
