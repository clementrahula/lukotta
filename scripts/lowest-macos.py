#!/usr/bin/env python3
"""The lowest macOS a build from this lock can run on.

    ./scripts/lowest-macos.py vendor/engine.lock

libblkid comes from a Homebrew bottle, and a bottle carries the minimum macOS
it was built for. So the floor is the engine's to decide, not a number typed
into Info.plist: build-app.sh asks this and writes the answer in as
LSMinimumSystemVersion. Ship a bottle built for a newer macOS with the plist
still saying 15.0 and Software Update offers the app to Macs it cannot load on.
"""
import json
import sys

# Homebrew names its bottles after the release; the linker wants the number.
FLOORS = {
    "monterey": "12.0",
    "ventura": "13.0",
    "sonoma": "14.0",
    "sequoia": "15.0",
    "tahoe": "26.0",
}


def main(path: str) -> int:
    lock = json.load(open(path))
    tags = {
        v["bottle_tag"]
        for v in lock.values()
        if isinstance(v, dict) and "bottle_tag" in v
    }
    if not tags:
        print(f"error: no bottle_tag in {path}", file=sys.stderr)
        return 1
    floors = []
    for tag in sorted(tags):
        name = tag.split("_", 1)[-1]
        if name not in FLOORS:
            print(
                f"error: unknown bottle tag {tag!r}. Add the macOS it was built "
                f"for to FLOORS in {__file__}.",
                file=sys.stderr,
            )
            return 1
        floors.append(FLOORS[name])
    # The highest floor wins: every bottle in the lock has to load.
    print(max(floors, key=lambda v: [int(p) for p in v.split(".")]))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
