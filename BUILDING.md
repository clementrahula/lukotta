# Building Lukotta from Source

<!-- covers: build-app.sh, scripts/fetch-engine.sh, scripts/vendor-engine.sh, scripts/build-engine.sh, scripts/build-guest-kernel.sh, scripts/build-ntfsck.sh, scripts/trim-image.py, scripts/collect-sources.sh, scripts/guest-sbom.py, scripts/generate-notices.sh, scripts/lowest-macos.py, scripts/release.sh, scripts/ship.sh, scripts/release-notes.py, scripts/notary-status.sh, scripts/preflight.sh, scripts/e2e.sh, scripts/run-tests.sh, scripts/lint.sh, scripts/make-test-volumes.sh checked: 2026-09-11 -->

Lukotta is GPL-3.0-or-later. Anyone who receives the app is entitled to its
source and to the scripts that build it. This covers the whole path, from a
clean machine to a signed application.

## Requirements

- An Apple Silicon Mac. The engine and every bundled library are `arm64`; there
  is no Intel build.
- macOS 15 or later, decided by the engine's Homebrew bottle. Pin a bottle built
  for a newer release and the floor rises with it; `build-app.sh` reads the floor
  from `vendor/engine.lock`, not from a number typed into the plist.
- Xcode's command line tools, with a Swift 6 toolchain.
- Docker, for `scripts/build-guest-kernel.sh` only.
- `shellcheck` and `swift-format`, for the linter only. `gitleaks` too, if you
  want the pre-commit hook's second pass; without it the hook runs the rest.

No package manager, no kernel extension, nothing installed system-wide.

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

- `swift build` alone produces an app that cannot unlock anything: the bundle
  needs the vendored engine and the compiled asset catalogue.
- `build-app.sh` needs `actool` from Xcode. Without it `Assets.xcassets` is
  copied uncompiled, and the app has no icon and no mark.

Builds are unbranded by default, the Lukotta name, wordmark and logo being
trademarks the GPL does not license. The software is otherwise identical. See
[Branding](#branding).

## Where the Engine Comes From

Lukotta mounts filesystems by handing the drive to a Linux virtual machine.
[anylinuxfs](https://github.com/nohajc/anylinuxfs), GPL-3, does that work and
ships inside the app.

`vendor/engine.lock` pins it exactly:

| | |
| --- | --- |
| `anylinuxfs` | version, the tap commit it came from, the bottle URL and its sha256 |
| `util-linux` | version, bottle URL and sha256; the engine links `libblkid` from it |
| guest image | the OCI manifest digest of the Alpine image |

`scripts/fetch-engine.sh` downloads those URLs and checks each against the
recorded sha256. A mismatch stops the build. Both checksums can be confirmed
against upstream independently: the anylinuxfs one appears in the tap's own
formula, the util-linux one in `formulae.brew.sh/api/formula/util-linux.json`.

The lock also decides the lowest macOS the finished app supports. `libblkid`
carries the minimum of the bottle it came from, so `bottle_tag` sets the floor:
`arm64_sonoma` is macOS 14, `arm64_sequoia` is 15, `arm64_tahoe` is 26. Lukotta
ships the sequoia bottles.

`build-app.sh` reads that floor from the lock (`scripts/lowest-macos.py`),
writes it into `LSMinimumSystemVersion`, then checks the built binary's own
`minos` against it and refuses to finish if the two disagree. Changing
`bottle_tag` to a newer release is therefore also a change to `Package.swift`'s
platform, and the build says so rather than shipping an app that Software
Update would offer to Macs it cannot load on.

### The two binaries built here

`anylinuxfs` and `vmproxy` carry patches. Both are built from the source tarball
pinned in `vendor/engine.lock`, checked against the same sha256 the release
verifies, with everything in `patches/` applied. Two crates the host binary
links in are fetched and patched the same way: imago, which reads the image
formats, and krun-devices, which requests one of them. The build compiles those
copies rather than the published ones. Everything else comes from the
checksummed bottle.

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

**This step is optional.** Skipped, the app is built with upstream's binaries
and refuses VMDK, VDI, VHD, VHDX and encryption inside an image by name.
`vendor-engine.sh` records which patches were applied and the app reads that
record, so it states what it can open either way. A release runs this step.

### The guest kernel

`build-engine.sh` applies every patch in `patches/` except the `linux-*` ones,
which belong to the guest kernel. `scripts/build-guest-kernel.sh` builds that
kernel in Docker, from the pins the engine's own `libexec/Image` came from,
with those patches applied:

    ./scripts/build-guest-kernel.sh vendor/kernel-built/Image

It writes `Image`, `Image.sha256` and `Image.patches`. `vendor-engine.sh` uses
that Image when all three are there and the sha256 matches, and adds the patch
names to the record. **After `build-engine.sh` this step is required:** its
vmproxy exports async only on this kernel, and `vendor-engine.sh` refuses to
package that vmproxy without it.

Docker runs headlessly: `docker desktop start`, never the Docker Desktop app.

## The Guest Image

The engine downloads the Alpine image the virtual machine boots, so it is the
one piece `fetch-engine.sh` does not. Create it once with the engine fetched
above:

```bash
./vendor/upstream/anylinuxfs/0.19.0/bin/anylinuxfs init
```

That writes `~/.anylinuxfs/alpine`. `vendor-engine.sh` checks it is the image
the lock names, umoci recording the manifest digest in the name of the mtree
file beside it, and refuses to build against a different one.

The image supports far more than Lukotta reaches and is trimmed to the packages
it uses. Source for every GPL package shipped must be published with the
release, so trimming cuts both the download and the work of complying. Set
`LUKOTTA_NO_TRIM=1` to keep the whole image.

### The NTFS checker

`ntfsfix` is not a chkdsk: it clears the dirty flag and repairs the boot sector,
and nothing in Alpine repairs the fault an interrupted copy actually leaves - an
index entry pointing at an MFT record that will not resolve, which then refuses
every operation on that name. `scripts/build-ntfsck.sh` builds a checker from
ntfsprogs-plus for the guest's architecture and libc:

    ./scripts/build-ntfsck.sh

It builds the revision `vendor/engine.lock` pins, which is the revision
`THIRD_PARTY_NOTICES.md` names and the one `collect-sources.sh` makes the
release's source archive from, and it fails rather than keep a binary built
from any other.

**This step is optional**, in the same way the patched engine is. Run it before
`vendor-engine.sh`, which copies the result into the image and says which it
did: `ntfsck added to the guest`, or `no ntfsck vendored`. Without it the app
behaves as it did before and cannot repair that damage.

### Adding a package to the guest

Two things are needed and neither implies the other. `scripts/trim-image.py`'s
`ROOTS` list decides what survives trimming, and a keep-list only keeps what is
already there, so the package has to be in the image first.

Install into the **standalone** image, not the app's engine home:

```bash
./vendor/upstream/anylinuxfs/0.19.0/bin/anylinuxfs apk add e2fsprogs xfsprogs
LUKOTTA_REPACK_GUEST=1 ./scripts/vendor-engine.sh
```

`vendor-engine.sh` will only pack an image carrying its own
`sha256_<digest>.mtree`, which is what the lock is checked against. The app's
engine homes under `~/Library/Application Support/com.lukotta*` are extracted
from the tarball this script produces and carry no mtree, so pointing at one
earns "the guest image is not the one vendor/engine.lock pins". Installing into
one of those changes the guest the app runs today and nothing that ships: the
feature works on the machine that added it and is missing from the release.

No machine may be running while `apk add` works.

Watch for `warning: roots not present in image` in the trim output. It names a
package the keep-list asks for that the image does not have, and it is the only
signal that the guest being packed is not the guest that was prepared.

### Nothing That Ships Names the Build Machine

- `umoci` writes the account, hostname and home directory of whoever ran
  `anylinuxfs init` into the header of the rootfs manifest. `vendor-engine.sh`
  drops that header when packing.
- `vendor-engine.sh` sweeps the vendored tree before packing, and `build-app.sh`
  sweeps the finished bundle before it reports done. Both sweep every file.
- A sweep counts matches. `strings | grep -q` under `pipefail` reports a match as
  a failure.

### Kernel modules nothing owns

Trimming removes the files each dropped package's own database entry names.
Some files belong to no package: `zfs.ko` and `spl.ko` live in the base image's
module tree, so dropping `zfs` and `zfs-libs` removes the userspace and leaves
the modules. `trim-image.py` removes `lib/modules/*/fs/zfs` by path for that
reason. Anything else added the same way needs the same treatment, and
`THIRD_PARTY_NOTICES.md` has to agree with the archive rather than the package
list.

## Building the App

`build-app.sh`, in order:

1. Runs the tests, and stops if any fail.
2. Works out the lowest macOS the engine's bottle allows, writes it into
   `LSMinimumSystemVersion`, and stops if the built binary disagrees.
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

- `LUKOTTA_DEVTOOLS=1` compiles in the headless harnesses: `--drive`, `--e2e`,
  `--update-test`, `--ux-check`. Without it they exist only in an
  unbranded build. A branded build handed one launches, hides its window, prints
  nothing and never exits.
- Development build: `LUKOTTA_BRANDING=dev LUKOTTA_DEVTOOLS=1 ./build-app.sh`.
- A bundle a harness drives against a real drive:
  `LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh`.
- `official` and `beta` builds are never copied into `/Applications`. An
  installed `Lukotta.app` or `Lukotta Beta.app` changes only through its own
  updater. A first install comes from the disk image or the cask.
- `dev` and unbranded builds install: "Lukotta Dev" under `com.lukotta.dev` and
  "Drive Unlocker" under `com.example.driveunlocker`, each with its own daemon
  and saved passphrases.
- `scripts/update-test.sh` is the one script that replaces an installed app. It
  keeps a copy of what was there and puts it back.
- `release.sh` passes `LUKOTTA_INSTALL=0`. `check-coverage.sh` checks that
  `build-app.sh` copies neither branded build, that `release.sh` writes nothing
  into `/Applications`, and that no other script copies over an installed app.
- No build, `dev` included, deletes a saved drive password. Only the Forget
  button or a confirmed uninstall removes one.

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

It answers `yes`, `no`, or `unknown`, and it will not answer `no` unless it used
a copy of notarytool able to read every kind of stored credential. The one
shipping with the Command Line Tools cannot, and reports working credentials as
missing. The build archives with `ditto`, which preserves the signature where
`zip` does not, submits it, and staples the ticket into the bundle so a first
launch works offline.

- `xcrun` resolves through `xcode-select`. Pointed at the Command Line Tools, it
  finds a `notarytool` that answers `No Keychain password item found for
  profile` for a profile that exists and works. `security
  find-generic-password` cannot see those credentials either. Neither error is
  evidence that notarisation is unconfigured.
- Whether notarisation is configured is answered only by
  `./scripts/notary-status.sh`. `unknown` is never read as `no`.
- `build-app.sh` prefers Xcode's `notarytool`.

## Verifying the Build

```bash
./scripts/run-tests.sh
./scripts/lint.sh
./scripts/preflight.sh    # what a release needs, in ten minutes
./scripts/e2e.sh          # everything, over an hour, a real Mac
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

The smoke test starts the app far enough to prove dyld resolved every library,
then exits. A build that installs and then refuses to launch cannot be undone by
an update.

`preflight.sh` runs before a release: a fresh install, a drive opened and
written to and ejected, an update applied as a whole archive and again as a
delta, one offered while a drive is open, a version that cannot start being put
back, and the disk image somebody downloads, on both channels.

`e2e.sh` is the whole thing: every image format, every filesystem it can build a
fixture for, the awkward names and the unhappy paths. It takes over an hour, so
it belongs to a night.

Both need a real Mac with Full Disk Access. `e2e.sh` builds its own fixtures the
first time, one with Homebrew's `mke2fs`, which it fetches if missing: the guest
carries mkfs for btrfs, NTFS and FAT only, and ext4 is what nearly every Linux
install puts on its volumes. A Mac with no Homebrew tests one filesystem fewer
and says so.

`scripts/make-test-volumes.sh` builds the LUKS layouts, including a volume group
of three volumes; `e2e.sh` uses those where they exist and says so where they do
not. To run either against the pre-release:

```bash
LUKOTTA_E2E_APP="/Applications/Lukotta Beta.app" ./scripts/e2e.sh
```

Both leave the Mac as they found it. Neither unmounts a drive that was already
open, or takes down an engine already serving one.

`build-app.sh` compares the binary's minimum macOS with the floor the engine's
bottle sets and refuses to finish if they disagree. To look at every library
yourself:

```bash
find dist/Lukotta.app -type f \( -perm -111 -o -name "*.dylib" \) | while read -r f; do
  otool -l "$f" 2>/dev/null | grep -A 3 LC_BUILD_VERSION | grep minos
done | sort -V | tail -1
```

## Branding

The build carries one of three identities.

| | Default | `LUKOTTA_BRANDING=official` | `LUKOTTA_BRANDING=beta` |
| --- | --- | --- | --- |
| Name | Drive Unlocker | Lukotta | Lukotta Beta |
| Bundle identifier | `com.example.driveunlocker` | `com.lukotta` | `com.lukotta.beta` |
| Icon and mark | A grey placeholder | The Lukotta artwork | The mark with a band across its foot |
| Update feed | none | `updates.lukotta.com/appcast.xml` | `updates.lukotta.com/beta/appcast.xml` |

The pre-release is the release everybody else gets a week later. It carries its
own identifier, daemon, saved passphrases and feed, so it can sit in the same
Dock as the release.

`example.com` is reserved by RFC 2606, so the unbranded identifier can never
collide with a real vendor.

All three are the same software. They differ in artwork, name, identifier and
feed, every one of which the code reads from the bundle at run time.

Use official branding to check a release against its source. Do not distribute
the result under that name: the GPL grants everything about the software and
nothing about the marks. TRADEMARKS.txt sets out what is permitted, including
giving a fork its own name and artwork.

- The unbranded default does not change. No identity is hard-coded in Swift: the
  code reads the name, identifier, icon and mark from the bundle.
- `LUKOTTA_BRANDING=dev`: "Lukotta Dev", `com.lukotta.dev`, the unbranded
  artwork, no update feed.
- On the `v2-coverage` branch, `LUKOTTA_BRANDING=v2` builds "Lukotta v2" with its
  own identifier, saved passphrases, engine home and feed, and automatic update
  checks off.

## Releasing

One command, which does every step between a finished build and somebody being
able to install it:

```bash
./scripts/ship.sh              # a beta
./scripts/ship.sh release      # the release channel
```

It moves the tag, marks the notes read, refuses on an uncommitted file while
saying which, and leaves nothing as a draft. Each of those was once a manual
step that stopped a release which was otherwise ready.

`ship.sh` calls `release.sh`, which is still the way to build and prepare
without publishing anything:

```bash
LUKOTTA_CHANNEL=beta LUKOTTA_PUBLISH=1 ./scripts/release.sh
LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

Both read the same `releases/<version>.md`, so the two cannot describe one build
differently. Without `LUKOTTA_PUBLISH=1` everything is built and nothing is
published, which is how to see what a release would say.

It builds with official branding, notarises and staples, checks the result
starts, archives it with `ditto`, signs the archive with the Sparkle key,
collects the corresponding source the GPL requires, and describes the lot in the
appcast.

### What each file should be

Every file a release uploads is digested, and the digests go up with them:
`SHA256SUMS.txt` as an attachment, and the same lines in the release page's own
text. Sparkle checks its download against a signature invisibly; this is for the
person taking the disk image from a page in a browser, or the source archive the
licence entitles them to. In the format `shasum` reads back, so checking is one
command:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### The notes

Nothing about a release is written by hand at release time.
`scripts/release-notes.py` drafts the notes for a version from the commits it is
made of, keeping the ones that changed something the app ships and dropping the
tooling, the tests and the documents. `bump-version.sh` writes that draft as
`releases/<version>.md` with the version itself, so it is in the repository from
the moment the version exists.

Edit that file. The draft is accurate about what changed and says it in the
words of whoever made the change; what goes out should be in the words of the
person reading it, and should leave out what they gain nothing from.

The release reads from the last version actually **published**, not the last one
tagged, since a version can be tagged here and never released. So the notes
describe everything the people receiving the update have not seen.

Before anything is built, the notes are printed in full and the release asks
whether they go out. No machine can check that part.
`LUKOTTA_NOTES_REVIEWED=1` says they were read somewhere else, for a release
with nobody at the keyboard.

### Re-vendoring after a change to the engine

`scripts/vendor-engine.sh` keeps the Linux guest it has already vendored and
refreshes the binaries around it. That is what a change to the host side wants,
and it is what makes the script safe to run twice: packing a guest means
trimming an untrimmed image, and on a Mac that has built this before, every copy
to hand is already trimmed. Trimming one of those empties it.

`LUKOTTA_REPACK_GUEST=1` packs a new one, and needs an image nothing has
trimmed: `anylinuxfs init` writes one into `~/.anylinuxfs`.

Notarisation needs the Mac unlocked. The credential lives in the Local Items
keychain, which locks with the session, and a locked one is reported as a
credential that does not exist. `./scripts/notary-status.sh` says which it is.

The feed lives in its own repository,
[lukotta-appcast](https://github.com/clementrahula/lukotta-appcast), served by
GitHub Pages at `updates.lukotta.com`. The website has a repository of its own,
so each has its own Pages site and domain. Point `LUKOTTA_APPCAST` at a checkout
and the release writes the appcast and the notes straight in:

```bash
git clone https://github.com/clementrahula/lukotta-appcast ../lukotta-appcast
LUKOTTA_APPCAST=../lukotta-appcast/appcast.xml LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

Both channels are served from that one site. The pre-release feed is a directory
in it rather than a domain of its own, since a Pages site carries exactly one
custom domain and a second hostname would mean a second repository and a second
certificate for one file:

```bash
LUKOTTA_CHANNEL=beta LUKOTTA_APPCAST=../lukotta-appcast/beta/appcast.xml \
  LUKOTTA_PUBLISH=1 ./scripts/release.sh
```

The notes go beside whichever feed is written, so the app finds them under
`updates.lukotta.com/notes/` or `updates.lukotta.com/beta/notes/`.

Then commit and push that checkout. Without it the appcast and notes are left in
`dist/` to be copied across by hand.

Updates from earlier versions are built when there is something to compare
against: put the archives of previous releases in `dist/previous`, or point
`LUKOTTA_PREVIOUS` at a directory of them. Sparkle then sends somebody on an
earlier build only what changed rather than ninety megabytes. With none there,
everybody downloads the whole archive, as they do for a first release.

### Channels

- Both channels publish as the work is ready. Publishing to either is approved,
  standing and in advance. The beta channel is not gated.
- One fix at a time, each through the whole path:
  1. Dev build, measured there: `LUKOTTA_BRANDING=dev LUKOTTA_DEVTOOLS=1 ./build-app.sh`.
  2. Beta: `./scripts/ship.sh`.
  3. The whole app exercised on the beta, not only the fix.
  4. Release: `./scripts/ship.sh release --approved`.
- `ship.sh release` runs `beta-proven.sh`, which refuses unless `prove-beta.sh`
  proved a beta of that version: its log is the one recorded, every step passed,
  no speed fell more than a quarter, and nothing outside `releases/` changed
  since.
- `prove-beta.sh` runs on the published beta, and is the only writer of
  `releases/proofs/` and `releases/BETA-PROVEN`. It commits and pushes them.
- `ship.sh` runs every check before compiling, commits and pushes the appcast
  and cask checkouts, and runs from a copy of itself.
- `releases/APPROVED` names the version beside the hash of
  `releases/<version>.md` as it stands; `release.sh` refuses otherwise.

| Channel | Feed | Cask |
| --- | --- | --- |
| release | `https://updates.lukotta.com/appcast.xml` | `clementrahula/tap/lukotta` |
| beta | `https://updates.lukotta.com/beta/appcast.xml` | `clementrahula/tap/lukotta@beta` |

- Artefacts: `dist/<slug>.dmg`, `dist/<slug>-<version>.zip`, the delta updates
  beside them, the appcast, the notes, `SHA256SUMS.txt`, and a GitHub release on
  `clementrahula/lukotta`.
- `ship.sh` fetches the live feed after publishing and checks it. By hand:

  ```bash
  curl -fsS https://updates.lukotta.com/appcast.xml \
    | grep -oE 'sparkle:shortVersionString>[^<]*' | head -1
  curl -fsIL https://github.com/clementrahula/lukotta/releases/latest/download/Lukotta.dmg \
    | grep -iE '^HTTP|^content-length' | tail -2
  ```

### Release Hazards

- Sparkle offers an update only on a higher build number: `sparkle:version`, the
  commit count. A hotfix cut from a shorter branch, a squash merge or a rewrite
  produces a number already published, and Sparkle answers "up to date". The
  release checks the published feed; that check is not worked around.
- `ship.sh` is not edited while it runs, and `dist/` is not rebuilt during a
  ship. A devtools build dropped on the shipping bundle made the closing summary
  read a bundle with no `SUFeedURL`, which ended the run after the GitHub
  release was published and before the appcast was committed.
- Nothing after the publish step ends a run by failing to print; the closing
  summary of `release.sh` tolerates a missing key.

### Versions

- `VERSION` holds the version being worked towards, plain semver: `1.20.1`.
  Nothing else goes in it.
- Betas are `1.20.1-beta.1`, `1.20.1-beta.2`; the release is `1.20.1`. The suffix
  is not in `VERSION`: `release.sh` adds it on the beta channel, numbered from
  the beta feed.
- Tags: `v1.20.1-beta.1`, `v1.20.1`. The casks use `v#{version}` on both
  channels.
- Sparkle compares `sparkle:version`. `CFBundleShortVersionString` is shown, not
  compared.
- The About sheet shows the version with the build in brackets:
  `1.20.1-beta.1 (612)`.
- `VERSION` is bumped as work lands, once committed and its tests pass:
  `./scripts/bump-version.sh patch` for a fix, `minor` for a feature. Raising the
  first number needs `--approved`.
- Every bump is tagged `v<version>`; `--no-tag` skips it. Push with
  `git push origin main --follow-tags`.
- There is no changelog file. Each version, pre-releases included, has
  `releases/<version>.md`.

### Notes and Translations

- `scripts/check-changelog.py` refuses developer verbs. `release.sh` and
  `ship.sh` run it before anything is published.
- Pre-release notes stay in English. Only release-channel notes are translated.
- Order:
  1. The English is written and cut back: `releases/<version>.md`, one bullet a
     line.
  2. The owner edits and approves it: a line in `releases/APPROVED` naming the
     version and the hash of those words. Nothing is translated before this.
  3. Drafts go in `releases/notes/<version>/<lang>.md`, same shape. The first
     line is `<!-- heading: … -->`, that language's word for "Version".
  4. The pack: `./scripts/notes-audit.py <version> --zip`. It carries the
     approved English, the drafts, and the glossary built from
     `translations/context/terms.json`, and no earlier releases. A term that must
     stay consistent between versions goes in the glossary.
  5. The owner audits the pack in a different model. The review is advisory;
     a proposal without a reason is discarded.
  6. What survives is applied, and the release goes out. `release.sh` writes a
     page per language and names each in the appcast with its `xml:lang`. A
     missing language gets the English notes.
- A release with no translations still goes out; `release.sh` says so.

## Reproducing a Released Build

Check out the tag and build with `LUKOTTA_BRANDING=official`, which is what
`scripts/release.sh` does. The engine comes from the lock rather than from your
machine, so the same tag produces the same engine on any Apple Silicon Mac.

Two things still differ: the signature, which depends on your certificate, and
the build number, which is the commit count at the tag.

## Corresponding Source

The GPL obliges whoever distributes the app to offer source for its GPL parts.

```bash
./scripts/collect-sources.sh
```

Nearly half a gigabyte, and nearly all of it the same bytes as the last release:
the kernel, gcc, every Alpine tarball. Each fetch is kept in
`vendor/.cache/sources` under the hash of the URL it came from and taken from
there next time. The first collection takes ten minutes; the next takes eight
seconds. A dependency that moves has a new URL and is fetched afresh. What is
stored is checked against the digest written beside it, so a half-written cache
entry is fetched again instead of shipped.

`LUKOTTA_SOURCE_CACHE` puts the cache somewhere else, and deleting it costs one
download.

Four components are always fetched: libkrun, libkrunfw, gvproxy and vmnet-helper
are named by branch rather than version, so a stored copy would be the last
release's source under this release's name. They are also the small ones.

That assembles source for the engine and for every package in the guest image
into `dist/sources`, matched to what is shipped rather than to what upstream
offers.

`vendor/guest-sbom.json` is the package database of the trimmed image as a
CycloneDX SBOM, written by `scripts/guest-sbom.py` during `vendor-engine.sh`.
It is one of the two tracked files under `vendor/`, because the audit workflow
scans it on a Linux runner that has no vendor tree and no macOS build.

`THIRD_PARTY_NOTICES.md` is kept by hand. Its guest package table alone is
rendered from that SBOM by `scripts/generate-notices.sh`, which
`vendor-engine.sh` runs itself, so a repack cannot write one file and leave the
other. The same script with `--check` is what the audit workflow and the
`noticesmatchtheimage` row run, and it needs nothing but a checkout.
