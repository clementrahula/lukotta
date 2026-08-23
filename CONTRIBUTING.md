# Contributing to Lukotta

Lukotta is GPL-3.0-or-later. Anyone receiving the app is entitled to its source
and to the scripts that build it, so this repository holds everything needed to
produce a working copy.

## Before You Start

Open an issue before writing anything substantial.

PRs are welcome:
- Bugs, with a way to reproduce them.
- A filesystem, encryption scheme or image format that macOS cannot open on its
  own. [SPECS.md](SPECS.md) governs these: what is supported already, what is out of scope, and the rule behind each. Read it first.
- Translations, and corrections to existing ones.
- Accessibility: anything a screen reader cannot reach, or a layout that breaks
  at larger text sizes.
- Tests for something that is not covered.

What tends not to be:
- Refactoring for its own sake.
- Features that belong in another app. Lukotta opens drives macOS cannot. It is
  not a disk utility.

## Building

[BUILDING.md](BUILDING.md) covers requirements, the build, its switches, and
signing. In short:

```bash
git config core.hooksPath .githooks   # once, per clone
./scripts/vendor-engine.sh
./build-app.sh
```

That produces `Drive Unlocker.app`. Builds are unbranded unless you set
`LUKOTTA_BRANDING=official`, the name and logo being trademarks the GPL does not
cover. The software is the same either way.

## Verifying Your Work

```bash
./scripts/run-tests.sh    # the unit tests
./scripts/lint.sh         # swift-format, shellcheck, and the coverage gate
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

`./scripts/e2e.sh` drives the whole flow against real images and needs Full Disk
Access and a Mac. It is worth running for anything touching mounting.

## Sending a Change

- Branch from `main`. One concern per pull request; two unrelated fixes are two
  pull requests.
- Commits are self-contained, and the message says why, not what. The diff
  already says what.
- Rebase rather than merge, so the history stays readable.
- Say what you tested it against — which drive, which image, which macOS.
  "Tests pass" is not that.
- Draft pull requests are fine and useful early.

Expect days rather than hours, and nudge the
thread if a week goes by. A change that is declined gets a reason.

## Translations

Twenty-one languages live in `translations/`, one JSON file each, built into the
string catalogue by `scripts/make-catalog.py`. `./scripts/lint.sh` fails when a
language is short of a string, so a half-finished translation cannot ship
quietly.

Corrections are as welcome as new languages. If a phrase reads badly to you as
a native speaker, it reads badly — say so in an issue if you would rather not
send a patch.

The English is the source. If a string is awkward in English, fix that first —
twenty-one translations of a bad sentence is twenty-one problems.

## Using AI

Lukotta was largely written by AI agents, and the README says so. Use whatever
tools you like.

The one thing that matters: a contribution should be worth more than the time it
takes to review. Generating a patch takes seconds; working out whether it is
right still takes an hour. Sending something you have not looked at moves that
hour to someone else.

- You are the author. Expect questions about your patch, and be able to answer
  them.
- Test it. The unit checks and the lint must pass. If it touches mounting, a
  format or the privileged helper, say what you ran it against.
- Give it more than one pass. First drafts read like first drafts, in the code
  and in the commit message.
- No slop: padding, restated code, invented history, a summary of what the diff
  plainly does.
- Leave the comments and documents around your change in better shape than you
  found them.
- Watch what a tool pastes in. If something recognisable came from elsewhere,
  say where.

A frontier model reasoning properly and a cheap one guessing produce visibly
different diffs. Use the best you have and give it room.

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
| `translations/` | One JSON file per language, built into the string catalogue. |
| `patches/` | Changes to the engine and the crates it links. Somebody else's code, under their licence. |
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

Nobody needs an encrypted drive, or a drive at all, to work on this.

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
- Fixtures are invented. Real output from your machine is sanitised in the same
  edit that pastes it.

## Reporting a Problem

**Open an issue.** <https://github.com/clementrahula/lukotta/issues> — the
templates ask what is needed to act on it. A public thread means the next person
with the same drive finds the answer.

The bug icon in the app gathers the version, the environment and the engine's
own output, removes credentials from it by value rather than by pattern, and
shows you everything before it sends. That report goes to
**lukotta@rahula.dev**, and it is the right route when the report carries
something you would rather not publish — a drive's name, a path, the layout of
your disks — or when you have no GitHub account.

Anything that could expose a passphrase, a drive's contents, or the privileged
helper goes to that address and not to an issue. [SECURITY.md](SECURITY.md) says
what is in scope and what to include.

## Licence

Contributions to Lukotta are accepted under GPL-3.0-or-later, the project's own
licence. There is no contributor agreement to sign: what goes out is what came
in.

What the project carries is not all GPL and keeps its own terms. Sparkle is MIT
with BSD and zlib components; the patches under `patches/` apply to imago (MIT)
and krun-devices (Apache-2.0); the engine, the guest and the Linux components
inside it are a mix of GPL-2, LGPL and Apache-2.0.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records what ships under what,
and `scripts/collect-sources.sh` assembles the corresponding source that must
accompany a release.

A patch to a file under `patches/` is a patch to somebody else's project, so it
carries their licence and not this one. The files there say which.

The name and the logo are trademarks and are not covered by the GPL, as
[TRADEMARKS.txt](TRADEMARKS.txt) sets out, so a fork is welcome under its own
name.
