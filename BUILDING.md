# Building Lukotta from Source

Lukotta is GPL-3.0. Anyone who receives the app is entitled to its source and
to the scripts that build it, so here is the whole path — from a clean
machine to a signed application.

## Requirements

- An Apple Silicon Mac. The engine and every bundled library are `arm64`; there
  is no Intel build.
- macOS 15 or later.
- Xcode's command line tools, with a Swift 6 toolchain.
- `shellcheck` and `swift-format`, for the linter only.

No package manager, no kernel extension, nothing installed system-wide.

## Quick Start

```bash
git clone https://github.com/clementrahula/lukotta.git
cd lukotta
./scripts/fetch-engine.sh      # download the pinned engine, verify checksums
./scripts/vendor-engine.sh     # stage it into vendor/engine
./build-app.sh                 # compile, embed, sign, install
```

The result is `dist/Drive Unlocker.app`, and a copy in `/Applications`.

Builds are unbranded by default: the Lukotta name, wordmark and logo are
trademarks, and the GPL does not license them. Everything else about the build
is the same. See [Branding](#branding).

## Where the Engine Comes From

Lukotta mounts filesystems by handing the drive to a Linux virtual machine.
That work is done by [anylinuxfs](https://github.com/nohajc/anylinuxfs), GPL-3,
shipped inside the app.

`vendor/engine.lock` pins it exactly:

| | |
| --- | --- |
| `anylinuxfs` | version, the tap commit it came from, the bottle URL and its sha256 |
| `util-linux` | version, bottle URL and sha256 — the engine links `libblkid` from it |
| guest image | the OCI manifest digest of the Alpine image |

`scripts/fetch-engine.sh` downloads those URLs and checks each against the
recorded sha256. A mismatch stops the build. The two checksums can be confirmed
against upstream independently: the anylinuxfs one appears in the tap's own
formula, and the util-linux one in `formulae.brew.sh/api/formula/util-
linux.json`.

The lock also decides the lowest macOS the finished app supports. `libblkid`
carries the minimum of the bottle it came from, so `bottle_tag` sets the floor:
`arm64_sonoma` is macOS 14, `arm64_sequoia` is 15, `arm64_tahoe` is 26. Lukotta
ships the sequoia bottles.


### The two binaries we build ourselves

Two of the engine's binaries carry patches of ours — `anylinuxfs` and `vmproxy`.
They are built from the source tarball pinned in `vendor/engine.lock`, checked
against the same sha256 the release verifies, with everything in `patches/`
applied. Everything else still comes from the checksummed bottle.

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

**This step is optional.** Skip it and the app is built with upstream's binaries
and works — without the two fixes. `vendor-engine.sh` records which patches went
in, and the app reads that file rather than assuming, so it says what it can do
either way. A release should always run it.

## The Guest Image

The Alpine image the virtual machine boots is downloaded by the engine rather
than shipped in the bottle, so it is the one piece `fetch-engine.sh` does not
download. Create it once with the engine you just fetched:

```bash
./vendor/upstream/anylinuxfs/0.19.0/bin/anylinuxfs init
```

That writes `~/.anylinuxfs/alpine`. `vendor-engine.sh` checks it is the image
the lock names — umoci records the manifest digest in the name of the mtree
file beside the image — and refuses to build against a different one.

The image is then trimmed to the packages Lukotta can reach; it arrives
supporting far more than that. Every GPL package shipped is one whose source
must be published with the release, so this makes both the download and the
compliance surface smaller. Set `LUKOTTA_NO_TRIM=1` to keep the whole image.

## Building the App

`build-app.sh`, in order:

1. Runs the tests, and stops if any fail.
2. Compiles the SwiftPM targets.
3. Assembles the bundle and copies `vendor/engine` into it.
4. Embeds the Sparkle framework and sets the runtime search path.
5. Signs from the inside out — nested code before the code containing it.
6. Verifies the signature, then installs to `/Applications`.

Switches:

```bash
LUKOTTA_INSTALL=0 ./build-app.sh              # build without installing
LUKOTTA_SKIP_TESTS=1 ./build-app.sh           # for iteration; never ship this
LUKOTTA_SIGN_ID="Developer ID Application: …" ./build-app.sh
LUKOTTA_NOTARY_PROFILE="name" ./build-app.sh  # also notarise and staple
LUKOTTA_BRANDING=official ./build-app.sh      # build as Lukotta
```

The version comes from `VERSION`; the build number is the commit count, so it
moves only when something is committed.

## Signing and Notarising

Without a Developer ID the app is signed ad-hoc, which is enough to run on the
machine that built it. To give it to anyone else it must be notarised, or
Gatekeeper will refuse it. Store credentials once:

```bash
xcrun notarytool store-credentials "lukotta" --apple-id YOU --team-id TEAM
```

Then build with `LUKOTTA_NOTARY_PROFILE="lukotta"`. The build archives it with
`ditto`, which preserves the signature where `zip` does not, submits it, and
staples the ticket into the bundle so a first launch works offline.

## Verifying the Build

```bash
./scripts/run-tests.sh
./scripts/lint.sh
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

The smoke test starts the app far enough to prove dyld resolved every library
and exits. It exists because a build that installs and then refuses to launch
is the one failure an update cannot undo.

To see the lowest macOS your build supports:

```bash
find dist/Lukotta.app -type f \( -perm -111 -o -name "*.dylib" \) | while read -r f; do
  otool -l "$f" 2>/dev/null | grep -A 3 LC_BUILD_VERSION | grep minos
done | sort -V | tail -1
```

## Branding

The build carries one of two identities.

| | Default | `LUKOTTA_BRANDING=official` |
| --- | --- | --- |
| Name | Drive Unlocker | Lukotta |
| Bundle identifier | `com.example.driveunlocker` | `com.clementrahula.lukotta` |
| Icon and mark | A grey placeholder | The Lukotta artwork |

`example.com` is reserved by RFC 2606, so the unbranded identifier can never
collide with a real vendor.

The two builds are the same software. The only difference is the artwork, the
name and the identifier, and the code reads all three from the bundle at run
time rather than having them written into it.

Use official branding to check a release against its source. Do not distribute
the result under the name: the GPL grants you everything about the software and
nothing about the marks. TRADEMARKS.txt sets out what is permitted, and giving
a fork its own name and artwork is expressly among it.

## Reproducing a Released Build

Check out the tag and build with `LUKOTTA_BRANDING=official`, which is what
`scripts/release.sh` does. The engine comes from the lock rather than from your
machine, so the same tag produces the same engine on any Apple Silicon Mac.

Two things will still differ: the signature, which depends on your certificate,
and the build number, which is the commit count at the tag.

## Corresponding Source

The GPL obliges whoever distributes the app to offer source for its GPL parts.

```bash
./scripts/collect-sources.sh
```

That assembles source for the engine and for every package in the guest image
into `dist/sources`, matched to what is shipped rather than to what upstream
offers. `THIRD_PARTY_NOTICES.md` records each component and its licence, and is
generated from the package database of the trimmed image so it cannot drift
from what ships.