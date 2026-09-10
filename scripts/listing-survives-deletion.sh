#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Whether a folder can be listed and emptied at once, the way Finder deletes
# one: each entry is removed as it is read, before the next batch is asked for.
# Where a removal moves the listing's place, entries are skipped or come twice,
# and Finder ends with "some items had to be skipped".
#
#   FILES=3000 ./scripts/listing-survives-deletion.sh <folder on the volume>
set -u
TARGET="${!#}"
[ "$#" -ge 1 ] && [ -d "$TARGET" ] || {
  echo "usage: $0 <folder on the volume>" >&2; exit 64; }

/usr/bin/python3 - "$TARGET/listing-$$" "${FILES:-3000}" <<'PY'
import errno, os, shutil, sys, time

root, n = sys.argv[1], int(sys.argv[2])
os.mkdir(root)
t = time.time()
for i in range(n):
    with open(os.path.join(root, f"f{i:06d}"), "wb") as fh:
        fh.write(b"x")
made = time.time() - t

def empty_while_listing(created_meanwhile):
    seen, twice, gone = set(), 0, 0
    with os.scandir(root) as it:
        for i, entry in enumerate(it):
            if entry.name in seen:
                twice += 1
                continue
            seen.add(entry.name)
            try:
                os.unlink(entry.path)
            except FileNotFoundError:
                gone += 1
            if created_meanwhile and i % 7 == 0:
                with open(os.path.join(root, f"g{i:06d}"), "wb") as fh:
                    fh.write(b"y")
    return seen, twice, gone

t = time.time()
seen, twice, gone = empty_while_listing(created_meanwhile=False)
emptied = time.time() - t
left = os.listdir(root)
print(f"{n} files made in {made:.1f}s, listed and removed in {emptied:.1f}s: "
      f"{len(seen)} listed, {twice} twice, {gone} already gone, {len(left)} left")
ok = len(seen) == n and twice == 0 and gone == 0 and not left

# Created while it is listed, so index blocks split as well as shrink. Every
# file that was there from the start must come exactly once.
for i in range(n):
    with open(os.path.join(root, f"f{i:06d}"), "wb") as fh:
        fh.write(b"x")
seen, twice, gone = empty_while_listing(created_meanwhile=True)
originals = sum(1 for name in seen if name.startswith("f"))
print(f"with files created meanwhile: {originals} of {n} originals listed, "
      f"{twice} twice, {gone} already gone")
ok = ok and originals == n and twice == 0 and gone == 0

for name in os.listdir(root):
    os.unlink(os.path.join(root, name))
try:
    os.rmdir(root)
except OSError as e:
    print(f"the folder could not be removed: {errno.errorcode.get(e.errno, e.errno)}")
    shutil.rmtree(root, ignore_errors=True)
    ok = False
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
