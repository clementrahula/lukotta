# Contributing to Lukotta

Lukotta is GPL-3.0. Anyone receiving the app is entitled to its source and to
the scripts that build it, so everything needed to produce a working copy is
here rather than in someone's head.

## What you need

- An Apple Silicon Mac. The engine and every bundled library are `arm64`; there
  is no Intel build and no cross-compilation.
- macOS 15 or later.
- Xcode's command line tools, with a Swift 6 toolchain. The package declares
  `swift-tools-version: 6.0` and builds its targets in Swift 5 language mode.
- `shellcheck` and `swift-format` for the linter. Without them `scripts/lint.sh`
  will tell you which is missing.

Nothing else. There is no package manager step, no Homebrew dependency, and no
kernel extension.

## Building

```bash
./scripts/vendor-engine.sh    # stage the engine and Linux image into vendor/
./build-app.sh                # compile, embed, sign, install to /Applications
```

`build-app.sh` signs with whatever Developer ID it finds in your keychain, and
falls back to an ad-hoc signature if there is none — enough to run locally.

Useful switches:

```bash
LUKOTTA_INSTALL=0 ./build-app.sh          # build without touching /Applications
LUKOTTA_SKIP_TESTS=1 ./build-app.sh       # faster iteration; do not commit from this
LUKOTTA_SIGN_ID="Developer ID Application: …" ./build-app.sh
LUKOTTA_NOTARY_PROFILE="name" ./build-app.sh   # also notarise and staple
```

Notarising needs your own Apple credentials, stored once with
`xcrun notarytool store-credentials`. It is only needed to give the app to
someone else; a locally signed build runs fine on the machine that built it.

## Checking your work

```bash
./scripts/run-tests.sh    # the unit tests
./scripts/lint.sh         # swift-format and shellcheck
```

Both must pass. `build-app.sh` runs the tests itself and refuses to produce a
bundle from a failing tree, which is deliberate: the app reads raw disks and
runs part of itself as root.

To check that a built app actually starts — the one failure an update cannot
undo — ask it:

```bash
./dist/Lukotta.app/Contents/MacOS/Lukotta --smoke-test
```

## How it fits together

| Target | What it is |
| --- | --- |
| `LukottaCore` | The logic, with no interface and no privileges. Nearly everything testable lives here. |
| `Lukotta` | The SwiftUI app. |
| `LukottaHelper` | A privileged daemon, so unlocking does not ask for a password every time. It accepts parameters, never a command. |
| `LukottaTests` | A plain executable, not XCTest, so the suite runs anywhere with a toolchain. |

Mounting works by handing the drive to a Linux virtual machine, which unlocks it
and re-exports it over NFS to localhost. `Documentation/BACKGROUND.md` explains
why, and what was tried first.

## Test drives without encrypted hardware

```bash
./scripts/make-test-volumes.sh
```

Builds LUKS images covering the layouts Lukotta supports, including one with a
partition table and three logical volumes inside a single container. The
passphrase is printed when it finishes. The script also prints how to attach one
and run the app so that disk images appear alongside real drives.

## House style

- Comments explain **why**, not what. If a line needs saying at all, it is
  usually because the obvious thing was wrong.
- No historical narration in comments or documents — git remembers.
- Commit messages describe the reasoning, not just the change.
- British spelling in prose; Apple's spelling in API names.

## Reporting something

Use the bug icon in the app: it gathers the version, the environment and the
engine's own output, shows you exactly what would be sent, and sends nothing on
its own. Credentials are removed from that output by value, not by pattern.

Issues and patches: <https://github.com/clementrahula/lukotta>.

## Licence

Contributions are accepted under GPL-3.0, the same licence as the project. The
engine and the Linux components it carries are third-party GPL software;
`Documentation/THIRD_PARTY_NOTICES.md` records what is shipped and under what
terms, and `scripts/collect-sources.sh` assembles the corresponding source that
must accompany a release.
