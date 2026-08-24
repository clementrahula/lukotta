# Contributing to Lukotta

Contributions are welcome: code, translations, bug reports, or a note that a
sentence reads badly.

Lukotta is GPL-3.0-or-later. Anyone receiving the app is entitled to its source
and to the scripts that build it, so this repository holds everything needed to
produce a working copy.

## Where to Start

For anything substantial, an issue first is worth the five minutes: an approach
is easier to agree on before the code exists.

Pull requests are welcome for:
- Bugs, with a way to reproduce them.
- A filesystem, encryption scheme or image format that macOS cannot open on its
  own. [SPECS.md](SPECS.md) covers these: what is supported, what is out of
  scope, and the rule behind each. Worth reading first.
- Translations, and corrections to existing ones.
- Accessibility: anything a screen reader cannot reach, or a layout that breaks
  at larger text sizes.
- Tests for something that is not covered.

Less likely to land:
- Refactoring for its own sake.
- Features outside what the app is for. Lukotta opens drives macOS cannot read;
  a general disk utility is a different program.

## AI Use Policy

Lukotta was largely written by AI agents, and the README says so. Use whatever
tools you like.

Generating a patch takes seconds; working out whether it is right still takes
an hour. So the thing to aim at is that a contribution is worth more than the
time it takes to review.

- You are the author, so questions come to you rather than to the tool.
- Tests and lint pass before it is sent. If it touches mounting, a format or
  the privileged helper, say what you ran it against.
- Give it more than one pass.
- No slop: padding, restated code, invented history, a summary of what the diff
  plainly does.
- Comments and documents around the change get the same attention as the code.
- If a tool pastes in something recognisable from elsewhere, say where it came
  from.

Better models, given room to reason, produce noticeably better diffs. Use the
best you have.

## House Style

- English is used for code commenting, documentation and all project-related communications exclusively.
- Comments explain why rather than what. A line worth writing is one where the
  obvious reading is wrong.
- No historical narration in comments or documents; git remembers.
- Commit messages describe the reasoning as well as the change.
- Fixtures are invented. Real output from your machine is sanitised in the same
  edit that pastes it.
- Every source file starts with its SPDX identifier and the copyright line. A
  new file gets them; a file under `patches/` gets that project's instead.

## Sending a Change

- Branch from `main`. One concern per pull request; two unrelated fixes are two
  pull requests.
- Commits are self-contained, and the message says why, not what. The diff
  already says what.
- Rebase rather than merge, so the history stays readable.
- Say what you tested it against: which drive, which image, which macOS.
- Draft pull requests are fine and useful early.

One person reviews, so days rather than hours. A nudge after a week is welcome.
Anything declined comes with a reason.

## Reporting a Problem

**Open an issue.** <https://github.com/clementrahula/lukotta/issues> — the
templates ask for what is needed to act on it. A public thread means the next
person with the same drive finds the answer.

The bug icon in the app gathers the version, the environment and the engine's
own output, removes credentials from it by value rather than by pattern, and
shows you everything before it sends. That report goes to
**bugreport@lukotta.com**. Use it when the report carries something you would
rather not publish, such as a drive's name or the layout of your disks, or when
you have no GitHub account.

Anything that could expose a passphrase, a drive's contents, or the privileged
helper goes to that address and not to an issue. [SECURITY.md](SECURITY.md) says
what is in scope and what to include.

## Building

[BUILDING.md](BUILDING.md) covers requirements, the build, its switches, and
signing. In short:

```bash
git config core.hooksPath .githooks   # once, per clone
./scripts/vendor-engine.sh
./build-app.sh
```

The first line turns on a check that keeps anything of yours out of a commit:
your account name, a path from your machine, the UUID of a disk you have
attached. `lint.sh` and CI run the same check.

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

## Translations

Thirty-six languages live in `translations/`, one JSON file each, built into
the string catalogue by `scripts/make-catalog.py`. `./scripts/lint.sh` fails
when a language is short of a string, so a half-finished translation cannot
ship quietly.

`translations/context/` says what every string means, and is what makes a
translation reviewable by somebody who has never seen the app:

| File | What it holds |
| --- | --- |
| `strings.json` | One entry per English string: the screens it appears on, what it means, and what each placeholder carries. |
| `screens.json` | Every screen and sheet: when it is shown, what it is for, the tone it is written in. |
| `terms.json` | The words that are not free to translate, and the reason for each. |
| `README.md` | The rules a translation is judged by. |

Two of those rules are worth stating here. **Apple's words for Apple's things**:
a reader following the steps is looking at System Settings while they read, so
panes and folders are named as their own Mac names them — and left in English
where macOS is not offered in that language, because English is then what they
see. And **a sentence naming a button uses the button's own words**: if the
button says *Neu starten*, the sentence saying to click it does too.

`./scripts/translation-bundle.sh` zips the languages, the context and the
canonical English into one archive that refers to no source code, which is how
a translation goes out for review.

Adding a string means adding its context. `./scripts/context-skeleton.py
--write` makes the entry; the sentence explaining it is written by hand, and
the coverage gate fails while it is empty.

Corrections are as welcome as new languages. If a phrase reads badly to you as
a native speaker, it reads badly — say so in an issue if you would rather not
send a patch.

The English is the source. If a string is awkward in English, fix that first —
thirty-six translations of a bad sentence is thirty-six problems.

A file is named the way Apple names that locale — `pt-PT`, `zh-Hans`, `nb` —
because macOS matches the reader's own setting against those names. Nobody's Mac
is set to plain Spanish: it is set to Spanish (Mexico), and macOS finds `es` from
that on its own. It finds `pt-PT` from Brazilian Portuguese, `fil` from Tagalog,
`he` from Hebrew's old code, and where it finds nothing it moves to the next
language that reader asked for. A name in some other style breaks all of it
quietly, which is why there is a check for it.

### Right to left

Arabic and Hebrew mirror the interface. Three things keep that working, and all
three are easy to undo by accident:

- `.leading` and `.trailing`, never `.left` and `.right`.
- `isolated()` around a drive name, a file name or a path inside a translated
  sentence. Without it the quotation marks and slashes take the paragraph's
  direction and end up on the wrong side of the name.
- `.environment(\.layoutDirection, .leftToRight)` on anything monospaced: a
  path, a device identifier, the engine's own output. Those are read as
  characters in the order they were written.

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
is refused and on what rule. It is the reference for adding a format, or for
changing how one is judged. The engine's own modifications are described in
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
| `vendor/` | The Linux engine, fetched by the build. Ignored apart from `engine.lock`, which pins it. |

## Test Drives Without Encrypted Hardware

```bash
./scripts/make-test-volumes.sh
```

Builds LUKS images covering the layouts Lukotta supports, including one with a
partition table and three logical volumes inside a single container. It prints
the passphrase when it finishes, and how to attach an image and run the app so
that images appear alongside real drives.

No encrypted drive is needed to work on this, and no drive at all.

## Uninstalling a Build

The app removes itself from **Lukotta → Uninstall Lukotta…**. It ejects any
open drives, unregisters the background helper, deletes the Linux environment
and the settings, offers to delete saved passphrases, and moves itself to the
Bin. A development build removes itself the same way a released one does.

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
