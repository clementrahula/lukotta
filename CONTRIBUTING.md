# Contributing to Lukotta

Lukotta is GPL-3.0. Anyone receiving the app is entitled to its source and to
the scripts that build it, so everything needed to produce a working copy is
in this repository.

## Building

[BUILDING.md](BUILDING.md) covers requirements, the build, its switches, and
signing. In short:

```bash
./scripts/vendor-engine.sh
./build-app.sh
```

That produces `Drive Unlocker.app`. Builds are unbranded unless you ask for
`LUKOTTA_BRANDING=official`, because the name and logo are trademarks and the
GPL does not cover them. It is the same software either way.

## Verifying Your Work

```bash
./scripts/run-tests.sh    # the unit tests
./scripts/lint.sh         # swift-format and shellcheck
```

Both must pass. `build-app.sh` runs the tests itself and refuses to produce a
bundle from a failing tree, which is deliberate: the app reads raw disks and
runs part of itself as root.

To check that a built app starts — the one failure an update cannot undo — ask
it:

```bash
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

To check what a screen reader would find:

```bash
swift scripts/dump-accessibility.swift
```

It prints every control the running app exposes. A `desc=nil` is a control
nobody can use without seeing it.

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
partition table and three logical volumes inside a single container. The
passphrase is printed when it finishes. The script also prints how to attach
one and run the app so that disk images appear alongside real drives.

## Uninstalling a Build

The app removes itself from **Lukotta → Uninstall Lukotta…**. It ejects any
open drives, unregisters the background helper, deletes the Linux environment
and the settings, offers to delete saved passphrases, and moves itself to the
Bin. A development build removes itself the same way a released one does.

## House Style

- Comments explain **why**, not what. If a line needs saying at all, it is
  because the obvious thing was wrong.
- No historical narration in comments or documents — git remembers.
- Commit messages describe the reasoning, not just the change.
- British spelling in prose; Apple's spelling in API names.

## Reporting a Problem

Use the bug icon in the app: it gathers the version, the environment and the
engine's own output, shows you exactly what would be sent, and sends nothing
on its own. Credentials are removed from that output by value, not by pattern.

Issues and patches: <https://github.com/clementrahula/lukotta>.

## Licence

Contributions are accepted under GPL-3.0, the same licence as the project. The
name and the logo are trademarks and are not covered by it — see
[TRADEMARKS.txt](TRADEMARKS.txt) — so a fork is welcome under its own name.
The engine and the Linux components it carries are third-party GPL software;
`THIRD_PARTY_NOTICES.md` records what is shipped and under what terms, and
`scripts/collect-sources.sh` assembles the corresponding source that must
accompany a release.