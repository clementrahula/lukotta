# Contributing to Lukotta

Lukotta is GPL-3.0. Anyone receiving the app is entitled to its source and to
the scripts that build it, so this repository holds everything needed to produce
a working copy.

## Building

[BUILDING.md](BUILDING.md) covers requirements, the build, its switches, and
signing. In short:

```bash
./scripts/vendor-engine.sh
./build-app.sh
```

That produces `Drive Unlocker.app`. Builds are unbranded unless you set
`LUKOTTA_BRANDING=official`, the name and logo being trademarks the GPL does not
cover. The software is the same either way.

## Verifying Your Work

```bash
./scripts/run-tests.sh    # the unit tests
./scripts/lint.sh         # swift-format and shellcheck
```

Both must pass. `build-app.sh` runs the tests itself and refuses to produce a
bundle from a failing tree, since the app reads raw disks and runs part of
itself as root.

A build that installs and then refuses to launch is the one failure an update
cannot undo. To check that a built app starts:

```bash
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

To check what a screen reader would find:

```bash
swift scripts/dump-accessibility.swift
```

It prints every control the running app exposes. A `desc=nil` marks a control
that cannot be used without seeing it.

## How It Fits Together

| Target | What it is |
| --- | --- |
| `LukottaCore` | The logic, with no interface and no privileges. Nearly everything testable lives here. |
| `Lukotta` | The SwiftUI app. |
| `LukottaHelper` | A privileged daemon, so unlocking does not ask for a password every time. It accepts parameters, never a command. |
| `LukottaTests` | A plain executable, not XCTest, so the suite runs anywhere with a toolchain. |

Mounting works by handing the drive to a Linux virtual machine, which unlocks
it and re-exports it over NFS to localhost.

[SPECS.md](SPECS.md) specifies what that machine can open: the filesystems,
the encryption, the disk image formats and how each is read, together with what
is refused and on what rule. Read it before adding a format or changing how one
is judged. The engine's own modifications are described in
[patches/README.md](patches/README.md).

The top level holds the documents, the package manifest and `build-app.sh`.
Everything else is in one of these:

| Directory | What it is |
| --- | --- |
| `sources/` | Swift, one directory per target. Lowercase, and every target names its `path:`. |
| `scripts/` | The build, test, release and packaging scripts. |
| `resources/` | Files the build copies into the bundle rather than compiles. |
| `assets/` | Artwork. `assets/brand/` holds the originals and the renderings made from them. |
| `docs/` | **The website**, at lukotta.rahula.dev. GitHub Pages serves from the repository root or `docs/`, so it takes that name; the documentation is in the root. |
| `vendor/` | The Linux engine, fetched by the build. Ignored apart from `engine.lock`, which pins it. |

## Test Drives Without Encrypted Hardware

```bash
./scripts/make-test-volumes.sh
```

Builds LUKS images covering the layouts Lukotta supports, including one with a
partition table and three logical volumes inside a single container. It prints
the passphrase when it finishes, and how to attach an image and run the app so
that images appear alongside real drives.

## Uninstalling a Build

The app removes itself from **Lukotta → Uninstall Lukotta…**. It ejects any
open drives, unregisters the background helper, deletes the Linux environment
and the settings, offers to delete saved passphrases, and moves itself to the
Bin. A development build removes itself the same way a released one does.

## House Style

- Comments explain why rather than what. A line worth writing is one where the
  obvious reading is wrong.
- No historical narration in comments or documents; git remembers.
- Commit messages describe the reasoning as well as the change.
- British spelling in prose; Apple's spelling in API names.

## Reporting a Problem

Use the bug icon in the app. It gathers the version, the environment and the
engine's own output, shows what would be sent, and sends nothing on its own.
Credentials are removed from that output by value rather than by pattern.

Issues and patches: <https://github.com/clementrahula/lukotta>.

## Licence

Contributions are accepted under GPL-3.0, the same licence as the project. The
name and the logo are trademarks and are not covered by it, as
[TRADEMARKS.txt](TRADEMARKS.txt) sets out, so a fork is welcome under its own
name.
The engine and the Linux components it carries are third-party GPL software;
`THIRD_PARTY_NOTICES.md` records what is shipped and under what terms, and
`scripts/collect-sources.sh` assembles the corresponding source that must
accompany a release.