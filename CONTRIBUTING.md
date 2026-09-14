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

## UI Changes

A user-interface change is done when it has been run in the built application
and every way a person can reach it has been tried: from a cold start, by each
condition that shows it, by each button that dismisses it, and again after
quitting and launching. A snapshot proves a scene draws. It proves nothing
about when the scene appears, when it goes, or what it leaves behind, and that
is where the faults are.

Before a UI change is called done:

1. Build and install it with `./build-app.sh`, and open the built application. Not `swift build`.
2. Reach the change from a cold start.
3. Reach it every other way, and leave it every way. Shown once: quit, relaunch, confirm it is not shown again. Buttons: press each, and close without pressing any. Conditional: reach it by each condition.
4. Leave and come back: state written to the wrong place, or not written before the process ended.
5. Say which of these were run.

`Lukotta --ux-check` on a DEVTOOLS build drives these routes against the real `AppModel` with nobody clicking. It does not replace step 1.

## House Style

- English is used for code commenting, documentation and all project-related communications exclusively.
- Most code is generated and read through AI tools. It is not expected to be pretty and elegant, but it must work and be reliable.
- Comments explain why rather than what. A line worth writing is one where the
  obvious reading is wrong.
- No historical narration in comments or documents; git remembers.
- Every source file starts with its SPDX identifier and the copyright line. A
  new file gets them; a file under `patches/` gets that project's instead.
- The two header lines go after a shebang, and after `swift-tools-version` in
  `Package.swift`.
- `patches/` identifiers: MIT for imago, Apache-2.0 for krun-devices,
  GPL-3.0-or-later for anylinuxfs.
- Paths are named as `git ls-files` prints them: `sources/`, lowercase. On a
  case-insensitive disk `git add Sources/…` leaves tracked files unstaged.
- A script that makes anything temporary sources `tmp-root.sh` first, under its
  `set` line. `everyScriptThatMakesTemporaryThingsContainsThem` fails and names
  a script that does not. It moves `$TMPDIR` into `$TMPDIR/lukotta-work` for
  every child; `scripts/sweep-workspaces.sh` empties that directory by age. A
  trap is not a substitute: it does not run when a run is killed.

  ```bash
  . "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
  ```

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

```bash
./scripts/verify.sh       # every checkable claim, and which hold now
```

- `scripts/checks.tsv` holds one row per claim: id, tags, speed, claim, command.
  `FULL=1` runs the slow rows, `TAG=release` one set, `ID=goal7` one claim.
- A fix adds a row. A claim with no check yet is a row with an empty command,
  listed as unchecked.
- `swift test` prints `no tests found`. The tests are a plain executable run by
  `run-tests.sh`, which prints the count.
- A check belongs to the `group` it is written in. `group` does not nest: the
  inner name replaces the outer one and is not restored.
- To check compilation: `swift build -c release --product Lukotta`. A bundle is
  needed only for snapshots, `--smoke-test` and end-to-end runs.
- `build-app.sh` refuses to build on a failing test, so a tree broken on purpose
  can leave the previous binary in place. Check the binary's timestamp changed.
- `lint.sh` runs swift-format, shellcheck, `check-private.py`, `check-casks.sh`,
  the check that every workflow action is pinned to a commit, and
  `check-coverage.sh`.
- `lint.sh` and the pre-commit hook use Homebrew's `swift-format` (603.0.0),
  which CI uses. The toolchain's `swift format` (6.3.0) passes lines it refuses.
- CI (`checks.yml`) runs on a push to `main`, on pull requests and on request.
  It builds both shipped applications with `LUKOTTA_INSTALL=0
  LUKOTTA_SKIP_TESTS=1`, smoke-tests them, scans the whole history for anything
  private, and ends with `lint.sh`. A macOS runner is billed at ten times a
  Linux one while the repository is private.

| Run | What it answers |
| --- | --- |
| `scripts/run-tests.sh` | the logic, on any Mac, with no drive; seconds |
| `scripts/preflight.sh` | a release: install, open, write, eject, update, roll back, both channels |
| `scripts/e2e.sh` | every format, every filesystem, the awkward names, the unhappy paths; over an hour per channel |

### Against real hardware

The unit tests cover the script the app generates, not what a disk does with
it. Anything touching mounting, a filesystem or the copy path wants at least
one of these, and each prints numbers rather than a verdict:

| Script | What it answers |
| --- | --- |
| `make-test-volumes.sh` | builds the fixtures the rest need |
| `copy-torture.sh` | 2024 files copied and read back: non-ASCII and 255-byte names, sizes on the block and transfer boundaries, a sparse gigabyte, two thousand small files, deep paths |
| `integrity-vectors.sh` | the ways a copy does not finish: killed partway, unmounted under load, a full volume, permissions, concurrent writers, repeated cycles, the machine killed mid-write |
| `finder-copy-cycles.sh` | Finder's own copy engine, driven by osascript, at both extremes |
| `corrupt-corpus.sh` | 83 deliberately broken NTFS images; checks that a refusal leaves the volume byte-identical |
| `xattr-forks.sh` | what macOS attaches to a file and what survives the crossing |
| `readdir-under-copy.sh` | how long the folder being copied into takes to list |
| `eight-gig-pressure.sh` | a dozen volumes open at once, with memory constrained |
| `lvm-lock-rule.sh` | several logical volumes from one partition |
| `e2e.sh` | the whole flow through the built app for every image format |

Two habits are worth copying from them, because both have produced convincing
false results here.

**Say what the number is of.** A latency figure sampled from the wrong call is
still a real number and still worthless: `stat` on a mount root was sampled for
45 minutes as evidence that nothing stalled, while listing the busy directory at
the same moment took ten seconds.

**Prove the instrument can fire.** A counter that has never once reported
anything is indistinguishable from a clean run.
`watch-for-complaints.sh --probe` exists for that reason.

Do not sweep leftover state with `pkill -9 -f 'anylinuxfs mount'`. It matches
the machine serving somebody's real drive as readily as one serving a fixture,
and killing a machine mid-write loses what it was holding. Match the image under
test, and end machines with `SIGTERM`.

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

## End-to-End

`./scripts/e2e.sh` drives a flow through the built app with no window and no
person: open a container file, unlock it, rebuild the list underneath it, eject
it. Real engine, real helper, real `hdiutil`.

- Fixtures are built once into `~/Library/Caches/dev.lukotta.e2e`. Nothing of the
  user's is touched.
- A fixture is passed as `name=path`: one line in `e2e.sh`, one in
  `EndToEnd.swift`. `check-coverage.sh` fails when a format named in SPECS.md is
  built and never handed over. A fixture handed over and missing on disk is a
  counted failure.
- `openAndChoose` does the preamble every flow shares (start, scan, open, find
  the row) and checks each wait.
- `scanGeneration` counts scans actually applied. A step that waited on the
  phase passed against a broken rebuild. A new step is broken on purpose once and
  seen to fail.
- A killed run leaves image fixtures truncated, and thirty negative tests then
  report "it opened, rather than failing". Delete
  `~/Library/Caches/dev.lukotta.e2e` and re-run.
- `e2e.sh` is written in BSD dialect (`dd bs=1m`, `stat -f%z`). With GNU
  coreutils first on `PATH` those are errors, and `set -e` exits after the first
  `echo`.
- `update-test.sh` runs inside `preflight.sh`, and alone. It applies real
  updates through Sparkle against a feed served from this Mac: a full archive, a
  delta, one offered while a drive is open, and a build that cannot start being
  put back.

## Snapshots

Snapshots are not run, recorded or re-recorded.

- `./scripts/snapshots.sh` renders every screen from the built unbranded app and
  compares it with `tests/snapshots/`. It needs `./build-app.sh`; `run-tests.sh`
  skips it when there is no app.
- Baselines belong to the unbranded build: the header draws the app's own name.
- `--look` draws every screen into a temporary directory and leaves the
  baselines alone. `--look hu` draws one language.
- `--record` replaces baselines, and refuses a change wider than sixteen without
  `--all`. One screen is eight: English at two sizes in two appearances, and one
  picture each in German, Arabic, Japanese and Hindi.
- Those four languages are the four ways a layout breaks: text that runs long,
  an interface that turns round, lines that break without spaces, a script
  taller than its box.
- A capture is taken once two captures agree. SwiftUI settles over a turn of the
  run loop, and an SF Symbol drawn for the first time in a process later still.
- Scenes are hosted in an off-screen `NSWindow`. `ImageRenderer` returns the
  inside of a `ScrollView` empty.
- `dynamicTypeSize` does nothing on macOS: `.accessibility3` rendered
  byte-identical to `.large`. The second axis is window size.

## Code

One place for each of these:

| Job | Where |
| --- | --- |
| Run a program and collect its output | `run(_:_:timeout:)` in `Shell.swift` |
| Read the mount table | `mountTable()`, same file |
| Take apart one of its lines | `MountTableEntry`, same file |
| Read a big- or little-endian field | the `Data` extension in `ByteOrder.swift` |
| Ask how large a file is | `fileSize(atPath:)` in `DiskImage.swift` |

- Three spawns do not use `run`, each commented where it is: `EngineEnvironment`'s
  `tar` reads stderr as it arrives to count entries for progress; `MountProbe`'s
  `df` collects no output, so a wedged `df` is abandoned with no pipe open;
  `Mounter.mount` drives osascript through a FIFO.
- `AppModel` is one file of about eighteen hundred lines, navigated by its marked
  sections, and not split. Swift's `private` is file-scoped: members moved out
  become visible to the module, `activeCredential` among them, which holds the
  passphrase while a mount is in flight.
- Swift 6: a closure written inside `@MainActor` code is main-actor isolated, and
  an Objective-C API calling it on its own queue traps
  (`dispatch_assert_queue_fail`, SIGTRAP). A closure for `NSXPCConnection`,
  `NSWorkspace.recycle`, `DiskArbitration` or any API calling back on an unknown
  queue is created in a `nonisolated` function, usually static, and hops back
  with `Task { @MainActor in … }`. The shapes: `HelperClient.roundTrip` and
  `moveToTheBin`.
- After a change to `MountScript`, restart the helper: it links `LukottaCore`.

### Logging

- `os.Logger`, under the running bundle's identifier. `Log.subsystem` is the
  only definition.
- `log show --predicate 'subsystem == "com.lukotta"' --last 30m`. An unbranded
  build logs under `com.example.driveunlocker`. The helper logs under its app's
  subsystem; `category` tells them apart.
- On the development Mac Lukotta's lines never appear in `log show`, at any
  level. `log stream` works, and `--drive sweep` is the foreground instrument.
- An interpolated string is private by default and reads back as `<private>`.
  Anything meant to be legible says `privacy: .public`. A passphrase is never
  logged.

## Nothing Private in the Repository

No account name, no path from a real machine, no identifier of a real disk, no
recovery key a drive would accept. Real output used to shape a fixture is
sanitised in the same edit: `someone` is the account name, `/Users/someone` the
home directory, identifiers invented and shaped like the real thing.

```bash
./scripts/check-private.py            # everything git tracks
./scripts/check-private.py --staged   # what is about to be committed
```

- It refuses a recovery key satisfying BitLocker's arithmetic, a home directory
  with an unfamiliar name, an account name inside `mount` output, the UUID of any
  disk this Mac has had attached, and anything shaped like a signing team.
  Deliberate lookalikes are in `ALLOWED` inside it.
- The account and the host name are asked of the system on each run. Disk UUIDs
  are kept as digests inside `.git`; `--forget` drops them.
- No identifier of any person belongs in that script or anywhere in the
  repository.
- Removal after it is committed: `git-filter-repo --replace-text` over every
  commit, a force-push of every branch and tag, and a re-cut of any release whose
  source archive carries it. Search for fragments too: a key's undashed form,
  six digits quoted in an assertion.

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

A new or changed entry in `strings.json` carries `"audit": false` until it is
audited.

Corrections are as welcome as new languages. If a phrase reads badly to you as
a native speaker, it reads badly — say so in an issue if you would rather not
send a patch.

The English is the source. If a string is awkward in English, fix that first —
thirty-six translations of a bad sentence is thirty-six problems.

### Right to Left

Arabic and Hebrew mirror the interface. Three things keep that working, and all
three are easy to undo by accident:

- `.leading` and `.trailing`, never `.left` and `.right`.
- `isolated()` around a drive name, a file name or a path inside a translated
  sentence. Without it the quotation marks and slashes take the paragraph's
  direction and end up on the wrong side of the name.
- `.environment(\.layoutDirection, .leftToRight)` on anything monospaced: a
  path, a device identifier, the engine's own output. Those are read as
  characters in the order they were written.

## Architecture

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

## Testing Without Encrypted Hardware

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
