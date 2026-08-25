# Building Lukotta from Source

Lukotta is GPL-3.0-or-later. Anyone who receives the app is entitled to its
source and to the scripts that build it. This document covers the whole path,
from a clean machine to a signed application.

## Requirements

- An Apple Silicon Mac. The engine and every bundled library are `arm64`; there
  is no Intel build.
- macOS 15 or later, which the engine's Homebrew bottle decides. Pin a bottle
  built for a newer release and the floor rises with it; `build-app.sh` reads
  the floor from `vendor/engine.lock`, not from a number typed into the plist.
- Xcode's command line tools, with a Swift 6 toolchain.
- `shellcheck` and `swift-format`, for the linter only. `gitleaks` too, if you
  want the pre-commit hook's second pass; without it the hook runs the rest.

No package manager, no kernel extension and nothing installed system-wide are
required.

## Quick Start

```bash
git clone https://github.com/clementrahula/lukotta.git
cd lukotta
git config core.hooksPath .githooks   # the pre-commit checks
./scripts/fetch-engine.sh             # download the pinned engine, verify checksums
./scripts/vendor-engine.sh            # stage it into vendor/engine
./build-app.sh                        # compile, embed, sign, install
```

The result is `dist/Drive Unlocker.app`, and a copy in `/Applications`.

Builds are unbranded by default, the Lukotta name, wordmark and logo being
trademarks that the GPL does not license. The software is otherwise identical.
See [Branding](#branding).

## Where the Engine Comes From

Lukotta mounts filesystems by handing the drive to a Linux virtual machine.
That work is done by [anylinuxfs](https://github.com/nohajc/anylinuxfs), GPL-3,
shipped inside the app.

`vendor/engine.lock` pins it exactly:

| | |
| --- | --- |
| `anylinuxfs` | version, the tap commit it came from, the bottle URL and its sha256 |
| `util-linux` | version, bottle URL and sha256; the engine links `libblkid` from it |
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

`build-app.sh` reads that floor from the lock (`scripts/lowest-macos.py`) and
writes it into `LSMinimumSystemVersion`, then checks the built binary's own
`minos` against it and refuses to finish if the two disagree. Changing
`bottle_tag` to a newer release is therefore a change to `Package.swift`'s
platform as well, and the build says so instead of shipping an app that
Software Update would offer to Macs it cannot load on.


### The two binaries built here

Two of the engine's binaries carry patches: `anylinuxfs` and `vmproxy`. They are
built from the source tarball pinned in `vendor/engine.lock`, checked against
the same sha256 the release verifies, with everything in `patches/` applied. Two
crates the host binary links in are fetched and patched the same way: imago,
which reads the image formats, and krun-devices, which requests one of them. The
build compiles those copies, not the published ones. Everything else
comes from the checksummed bottle.

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

**This step is optional.** Skipped, the app is built with upstream's binaries
and refuses VMDK, VDI, VHD, VHDX and encryption inside an image by name.
`vendor-engine.sh` records which patches were applied and the app reads that
record, so it states what it can open either way. A release runs this step.

## The Guest Image

The Alpine image the virtual machine boots is downloaded by the engine rather
than shipped in the bottle, so it is the one piece `fetch-engine.sh` does not
download. Create it once with the engine fetched above:

```bash
./vendor/upstream/anylinuxfs/0.19.0/bin/anylinuxfs init
```

That writes `~/.anylinuxfs/alpine`. `vendor-engine.sh` checks it is the image
the lock names, umoci recording the manifest digest in the name of the mtree
file beside the image, and refuses to build against a different one.

The image arrives supporting far more than Lukotta reaches, and is trimmed to
the packages it uses. Source for every GPL package shipped must be published
with the release, so trimming cuts both the download and the work of
complying. Set `LUKOTTA_NO_TRIM=1` to keep the whole image.

## Building the App

`build-app.sh`, in order:

1. Runs the tests, and stops if any fail.
2. Works out the lowest macOS the engine's bottle allows, writes it into
   `LSMinimumSystemVersion`, and stops if the built binary disagrees with it.
3. Compiles the SwiftPM targets.
4. Assembles the bundle and copies `vendor/engine` into it.
5. Embeds the Sparkle framework and sets the runtime search path.
6. Signs from the inside out, nested code before the code containing it.
7. Verifies the signature, then installs to `/Applications`.

Switches:

```bash
LUKOTTA_INSTALL=0 ./build-app.sh              # build without installing
LUKOTTA_SKIP_TESTS=1 ./build-app.sh           # for iteration; never ship this
LUKOTTA_SIGN_ID="Developer ID Application: …" ./build-app.sh
LUKOTTA_NOTARY_PROFILE="name" ./build-app.sh  # also notarise and staple
LUKOTTA_BRANDING=official ./build-app.sh      # build as Lukotta
```

The version comes from `VERSION`; the build number is the commit count, so it
moves only when something is committed. Building with uncommitted changes
produces a second binary carrying the number the last one already has, and the
build says so as it starts.

## Signing and Notarising

Without a Developer ID the app is signed ad-hoc, which is enough to run on the
machine that built it. To give it to anyone else it must be notarised, or
Gatekeeper will refuse it.

Credentials are taken whichever way you hold them, and naming any of the three
switches notarisation on:

```bash
# a keychain profile, which is used automatically when it is called "lukotta"
xcrun notarytool store-credentials "lukotta" --apple-id YOU --team-id TEAM
LUKOTTA_NOTARY_PROFILE="other-name" ./build-app.sh

# an App Store Connect key
LUKOTTA_NOTARY_KEY=AuthKey.p8 LUKOTTA_NOTARY_KEY_ID=… LUKOTTA_NOTARY_ISSUER=… ./build-app.sh

# an Apple ID and an app-specific password
LUKOTTA_APPLE_ID=you@example.com LUKOTTA_APP_PASSWORD=… LUKOTTA_TEAM_ID=… ./build-app.sh
```

The build says which one it used.

To find out whether this machine has a credential at all:

```bash
./scripts/notary-status.sh
```

It answers `yes`, `no`, or `unknown`, and it will not answer `no` unless it
used a copy of notarytool able to read every kind of stored credential. The one
that ships with the Command Line Tools is not, and reports working credentials
as missing. The build archives it with
`ditto`, which preserves the signature where `zip` does not, submits it, and
staples the ticket into the bundle so a first launch works offline.

## Verifying the Build

```bash
./scripts/run-tests.sh
./scripts/lint.sh
./scripts/preflight.sh    # what a release needs, in about half an hour
./scripts/e2e.sh          # everything, over an hour, a real Mac
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

The smoke test starts the app far enough to prove that dyld resolved every
library, then exits. A build that installs and then refuses to launch is the one
failure an update cannot undo.

`preflight.sh` is what to run before a release: a fresh install, a drive opened
and written to and ejected, an update applied and rolled back, on both channels.
`e2e.sh` is the whole thing — every image format, every filesystem it can build
a fixture for, the awkward names and the unhappy paths — and takes long enough
that it belongs to a night rather than to a release.

Both need a real Mac with Full Disk Access. `e2e.sh` builds its own fixtures the
first time, one of them with Homebrew's `mke2fs`, which it fetches if it is
missing: the guest carries mkfs for btrfs, NTFS and FAT only, and ext4 is what
nearly every Linux install puts on its volumes. A Mac with no Homebrew tests one
filesystem fewer and says so.

`scripts/make-test-volumes.sh` builds the LUKS layouts, including a volume group
of three volumes; `e2e.sh` uses those where they exist and says so where they do
not.

`build-app.sh` already compares the binary's minimum macOS with the floor the
engine's bottle sets, and refuses to finish if they disagree. To look at every
library for yourself:

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

The two builds are the same software. They differ in artwork, name and
identifier, all three of which the code reads from the bundle at run time rather
than having them compiled in.

Use official branding to check a release against its source. Do not distribute
the result under that name: the GPL grants everything about the software and
nothing about the marks. TRADEMARKS.txt sets out what is permitted, including
giving a fork its own name and artwork.

## Releasing

A beta first, then the same version as the release once the beta holds up:

```bash
LUKOTTA_CHANNEL=beta LUKOTTA_PUBLISH=1 ./scripts/release.sh
LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

Both read the same `releases/<version>.md`, so the two cannot describe the same
build differently. Without `LUKOTTA_PUBLISH=1` everything is built and nothing
is published, which is how to see what a release would say.

It builds with official branding, notarises and staples, checks the result
starts, archives it with `ditto`, signs the archive with the Sparkle key,
collects the corresponding source the GPL requires, and describes the whole lot
in the appcast.

### What each file should be

Every file a release uploads is digested, and the digests go up with them:
`SHA256SUMS.txt` as an attachment, and the same lines in the release page's own
text. Sparkle checks its download against a signature and nobody sees that
happen; this is for the person who takes the disk image from a page in a
browser, or the source archive because the licence entitles them to it. In the
format `shasum` reads back, so checking is one command:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### The notes

Nothing about a release is written by hand at release time. The notes for a
version are drafted from the commits it is made of by
`scripts/release-notes.py`, which keeps the ones that changed something the app
ships and drops the tooling, the tests and the documents. `bump-version.sh`
writes that draft as `releases/<version>.md` with the version itself, so it is
in the repository from the moment the version exists.

Edit that file. The draft is accurate about what changed and says it in the
words of whoever made the change; what goes out should be in the words of the
person reading it, and should leave out what they gain nothing from.

The release reads from the last version actually **published**, not the last one
tagged, since a version can be tagged here and never released. So the notes
describe everything the people receiving the update have not seen.

Before anything is built, the notes are printed in full and the release asks
whether they go out. It is the one part of a release no machine can check.
`LUKOTTA_NOTES_REVIEWED=1` says they were read somewhere else, for a release
with nobody at the keyboard.

### Re-vendoring after a change to the engine

`scripts/vendor-engine.sh` keeps the Linux guest it has already vendored and
refreshes the binaries around it. That is what a change to the host side wants,
and it is what makes the script safe to run twice: packing a guest means
trimming an untrimmed image, and on a Mac that has built this before, every copy
to hand is a trimmed one — the application's own directory and the engine's,
both filled from a build. Trimming one of those leaves an image with nothing in
it.

`LUKOTTA_REPACK_GUEST=1` packs a new one, and needs an image nothing has
trimmed: `anylinuxfs init` writes one into `~/.anylinuxfs`.

Notarisation needs the Mac unlocked. The credential lives in the Local Items
keychain, which locks with the session, and a locked one is reported as a
credential that does not exist. `./scripts/notary-status.sh` says which it is.

The feed itself lives in its own repository,
[lukotta-appcast](https://github.com/clementrahula/lukotta-appcast), served by
GitHub Pages at `updates.lukotta.com`. The website lives in a repository of its
own, so each has its own Pages site and its own domain. Point `LUKOTTA_APPCAST` at a
checkout of it and the release writes the appcast and the notes straight in:

```bash
git clone https://github.com/clementrahula/lukotta-appcast ../lukotta-appcast
LUKOTTA_APPCAST=../lukotta-appcast/appcast.xml LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

Both channels are served from that one site. The pre-release feed is a
directory in it rather than a domain of its own, since a Pages site carries
exactly one custom domain and a second hostname would mean a second repository
and a second certificate, for one file:

```bash
LUKOTTA_CHANNEL=beta LUKOTTA_APPCAST=../lukotta-appcast/beta/appcast.xml \
  LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

The notes go beside whichever feed is being written, so the app finds them under
`updates.lukotta.com/notes/` or `updates.lukotta.com/beta/notes/`.

Then commit and push that checkout. Without it the appcast and notes are left in
`dist/` to be copied across by hand.

Updates from earlier versions are built when there is something to compare
against: put the archives of previous releases in `dist/previous`, or point
`LUKOTTA_PREVIOUS` at a directory of them. Sparkle then sends somebody on an
earlier build only what changed rather than ninety megabytes. With none there,
everybody downloads the whole archive, which is what the first release does.

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

Nearly half a gigabyte of it, and nearly all of it the same bytes as the last
release: the kernel, gcc, every Alpine tarball. Each fetch is therefore kept in
`vendor/.cache/sources` under the hash of the URL it came from, and taken from
there next time. The first collection takes ten minutes; the next takes eight
seconds. A dependency that moves has a new URL and is fetched afresh, and
nothing else is. What is stored is checked against the digest written beside
it, so a half-written cache entry is fetched again instead of shipped.

`LUKOTTA_SOURCE_CACHE` puts the cache somewhere else, and deleting it costs one
download.

Four components are always fetched: libkrun, libkrunfw, gvproxy and vmnet-helper
are named by branch rather than by version, so a stored copy would be the last
release's source under this release's name. They are also the small ones.

That assembles source for the engine and for every package in the guest image
into `dist/sources`, matched to what is shipped rather than to what upstream
offers. `THIRD_PARTY_NOTICES.md` records each component and its licence, and is
generated from the package database of the trimmed image, so it cannot drift
from what ships.