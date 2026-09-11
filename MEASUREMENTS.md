# Measurements

<!-- covers: scripts/** checked: 2026-09-11 -->

Finder's own copy and delete only.

## BitLocker stick, Finder copy — 2026-09-02

    5 files, three runs        1.7 s, 1.5 s, 1.5 s   all arrived
    204 files, 88 MB, two runs 20.8 s, 25.9 s        byte-identical
    Finder dialogs             0

## Finder copy cycles, 1.22.1 — 2026-09-02

    NTFS   3 x 42 MB      1 s a cycle     3 identical
    NTFS   2000 files    25 s a cycle     2000 identical
    ext4   3 x 30 MB      3 s a cycle     3 identical
    ext4   2000 files   101 s a cycle     2000 identical

Three cycles each, no dialog, no skip, no drift.

## Finder copy cycles, XFS — 2026-09-03

    cycle 1  3 x 306 MB   114 s   3 identical
    cycle 1  2000 files    81 s   2000 identical
    cycle 2  3 x 306 MB   117 s   3 identical
    cycle 2  2000 files    88 s   2000 identical

No dialog, no skip, no drift.

## Native exFAT stick against the BitLocker stick — 2026-09-10

    native exFAT, 1 GB in 4 files       10.9 MB/s, Copy window shown
    BitLocker, same copy, 128 KiB       5.0 MB/s, Copy window shown
    BitLocker, same copy, 1 MiB         7.4 MB/s, Copy window shown

On the native stick too:

    placeholders   a 20-file copy made all 20 destination files within 5 s,
                   19 of them empty
    ._ files       one per file
    cancel         one file: gone at once; twenty files: the one in flight
                   goes, 18 empty placeholders and their ._ files stay
    delete         0.49 s, into the Trash

## BitLocker stick, Finder delete and copy — 2026-09-11

    delete, 500 files                   1.0 s, no error
    delete, 5,002 files                 7.0 s, no error
    delete, 10,538 files                14.1 s, no error

                            BitLocker stick     native exFAT stick
    1 GB in 4 files         5.6 MB/s            8.0 MB/s (64 MB)
    500 files of 4 KiB      14.0 s              11.0 s
    delete of those 500     1.0 s               0.25 s, into the Trash

    500 files of 4 KiB, stable write syncing the whole filesystem   32.6 s
    40 zero-byte files, with the placeholder sweeper                all 40 kept

Cancelled with the Copy window's button, 20 files of 20 MB: the file in
flight gone in 0.6 s. With the placeholder sweeper, press to last empty file
gone: 1.4 s to 10.6 s.

As shipped in 1.22.16:

    500 files of 4 KiB          14.5 s
    64 MB                       6.3 MB/s
    delete of the 500           1.13 s
    80 folders of 3 files       byte-identical, no error

## Finder delete in place — 2026-09-11

    BitLocker stick, 2,000 one-byte files        2.99 s
    BitLocker stick, 1,000 empty files           1.48 s
    BitLocker stick, 3,000 files                 5.59 s
    native APFS image, Trash blocked, 2,000      283 ms
    native APFS image, in place, 5,000           358 ms
    BitLocker stick, 20 files, .Trashes made     256 ms, nothing in the Trash

## BitLocker stick, dev build of 1.22.17 — 2026-09-11

    finderparity                1 GB and 500 files byte-identical,
                                delete of the 500 with nothing skipped
    256 MiB in 4 files          43.9 s, 6.12 MB/s, identical
