# Notes for Coding Agents

This file lists the things about Lukotta that mislead: commands that report the
wrong thing, conventions that differ from the default, and rules that look like
details and are not.

[CONTRIBUTING.md](CONTRIBUTING.md) covers house style and how to submit work.
[BUILDING.md](BUILDING.md) covers requirements, switches, and signing. Read
those for everything this file leaves out.

## Commands That Report The Wrong Thing

`swift test` prints `no tests found`. The checks are a plain executable target,
run by `./scripts/run-tests.sh`, which reports the count. `swift test` is not
evidence that this project is untested.

A check belongs to the `group` it is written in, and `group` refuses to nest:
nested, the inner one takes over the name and never gives it back, so a later
failure in the outer group is reported under the inner group's name. Two topics
in one group is the mistake a stack of names would only make comfortable.

**Do not run `./build-app.sh` to check that something compiles.** `swift build
-c release --product Lukotta` does that in seconds. A bundle is only needed to
record or compare snapshots, to run `--smoke-test`, or to run the end-to-end
flow. Notarising is opt-in and belongs to a release: `scripts/release.sh` names
the profile, and nothing else should.

`swift build` succeeds and produces an app that cannot unlock anything. A
working bundle needs the Linux engine and the compiled asset catalogue:

```bash
./scripts/vendor-engine.sh    # downloads the pinned engine on first run
./build-app.sh
```

The app it builds is called **Drive Unlocker**, not Lukotta. Builds are
unbranded by default because the name and logo are trademarks that the GPL does
not cover; `LUKOTTA_BRANDING=official` is what `scripts/release.sh` uses. Do not
change that default, and do not hard-code either identity in Swift. The code
reads the name, identifier, icon and mark from the bundle at run time.

`build-app.sh` needs `actool` from Xcode. The SwiftPM command line copies
`Assets.xcassets` into the bundle without compiling it, which leaves the app
with no icon and no mark.

Run `./scripts/lint.sh` before committing. It is swift-format and shellcheck,
and also the coverage gate, the check that every workflow action is pinned to a
commit, and `scripts/check-private.py`.

CI runs on pull requests and on request, not on every push: a macOS runner is
billed at ten times a Linux one while the repository is private.

## Layout

Sources are in `sources/`, lowercase, and every target in `Package.swift`
carries an explicit `path:`. The conventional `Sources/` fails on a
case-sensitive volume.

The build number is the git commit count. Rebuilding without committing
reuses the previous number, so two different binaries claim the same build.
Commit before building anything you intend to compare; `build-app.sh` says so
as it starts when the tree is dirty.

Five jobs are done in one place each. Call these rather than writing another:

| Job | Where |
| --- | --- |
| Run a program and collect its output | `run(_:_:timeout:)` in `Shell.swift` |
| Read the mount table | `mountTable()`, same file |
| Take apart one of its lines | `MountTableEntry`, same file |
| Read a big- or little-endian field | the `Data` extension in `ByteOrder.swift` |
| Ask how large a file is | `fileSize(atPath:)` in `DiskImage.swift` |

Three spawns deliberately do not use `run`, and each says so where it is.
`EngineEnvironment`'s `tar` reads stderr as it arrives, to count entries for the
progress. `MountProbe`'s `df` collects no output at all, so that a `df` wedged
inside a syscall can be abandoned with no pipe left open on it. `Mounter.mount`
drives osascript through a FIFO. Leave all three.

`AppModel` is one file of about eighteen hundred lines, and splitting it costs
more than it saves. Swift's `private` is file-scoped, so members moved into
extensions elsewhere must become visible to the whole module, `activeCredential`
among them, which holds the passphrase while a mount is in flight. Navigate it
by its marked sections.

## The Engine

**The engine exits 0 when a mount fails.** Its status describes its own
shutdown. Judge a mount by the mount table, which is what
`MountScript.mountedCheck` does. Trusting the exit status disables every
fallback path in the generated script.

It compares the engine's mount points by name against a baseline, and looks for
one that was not there before. It does **not** count them: a count is a count of
everything, so an NFS share the person using the Mac had mounted themselves
joined the baseline, and one coming or going during an attempt moved the number
on its own.

Failures are explained by matching text, the exit status being meaningless:
`Diagnosis.rules` looks for phrases. Each rule
records whether the words are the engine's own or the Linux tooling's, and
`Diagnosis.enginesChecked` lists the engine versions the rules have been tried
against. **Bumping `vendor/engine.lock` fails a test until that list is
updated**, so that a rewording upstream cannot silently stop every rule from
firing.

**A mount that fails leaves the engine's network helper running.** `gvproxy`
carries the network the NFS connection is made over, and the engine takes it
down only when a mount it completed is ejected. An attempt that never mounted
anything leaves one behind holding the image file open, and the next attempt
then reports the file as locked. `Mounter` records which helpers were running
before it starts and takes down the ones the attempt added when it fails;
`EngineProcesses.tidyLeftovers` clears the rest at launch, and only when the
engine reports no mounts at all. Both match on the running bundle's own engine
path, so another copy of the app is left alone.

`MountScript` lives in `LukottaCore`, which the privileged helper links.
After changing it, restart the helper or you are testing the old script.

The engine is driven through a pty by `expect`, so its output arrives with
carriage returns. Strip `\r` before parsing or comparing.

The generated script embeds a single-quoted `awk` program. An apostrophe
anywhere inside it, including inside a comment, closes the quote and breaks the
whole script. A test runs `sh -n` over the generated output to catch this.

That program is `MountScript.volumeAction`, public so that a test can run it
with `awk -v s=… -v q="'" -v ro=…` over a captured listing. It is the only
reader of the engine's volume list that decides what gets mounted, and nothing
else can reach it.

## Finding Out What The App Did

Everything is logged with `os.Logger` under the running bundle's identifier,
which `Log.subsystem` is the only definition of. To read it back:

    log show --predicate 'subsystem == "com.clementrahula.lukotta"' --last 30m

An unbranded build logs under `com.example.driveunlocker`, and the privileged
helper logs under the same subsystem as the app it came from, so one predicate
catches both processes and the `category` tells them apart.

A string interpolated into a log message is private by default and reads back
as `<private>`, which is correct for a drive's name and for a path on someone's
disk. Anything meant to be legible says `privacy: .public`. A passphrase is
never logged.

## Every source file says what it is under

Two lines at the top of each Swift, shell and Python file:

    // SPDX-License-Identifier: GPL-3.0-or-later
    // Copyright (C) 2026 Clement Rahula

After the shebang where there is one, and after `swift-tools-version` in the
package manifest, since both have to come first. Files under `patches/` belong
to other projects and carry those projects' identifiers instead: MIT for
imago, Apache-2.0 for krun-devices, GPL-3.0-or-later for anylinuxfs.

The grant itself is in README's licence section, in full, because "GPL-3.0-or-
later" is a shorthand for a sentence somebody has to have written.

## Fixtures are invented, never captured

Nothing of the owner's goes in this repository: no account name, no path from
their machine, no identifier of a disk they own, no recovery key that a drive
would accept. None of it looks like a secret and no scanner recognises it,
which is why it got in before.

When real output is needed to get a fixture's shape right, sanitise it in the
same edit that pastes it. `someone` is the account name; `/Users/someone` is
the home directory; identifiers are made up and shaped like the real thing.

    ./scripts/check-private.py            everything git tracks
    ./scripts/check-private.py --staged   what is about to be committed

It refuses a recovery key that satisfies BitLocker's own arithmetic, a home
directory with an unfamiliar name, an account name inside `mount` output, the
UUID of any disk this Mac has ever had attached, and anything shaped like a
signing team. Deliberate lookalikes are listed in `ALLOWED` inside it.

Who to refuse is asked of the system on each run, and kept nowhere: the account
it runs as, and the name this Mac answers to. Disks are the exception, because a
drive gets unplugged between capturing a fixture and committing it; those are
remembered as digests, written on demand into `.git`, which git cannot see and
which never leaves the machine. `--forget` drops them, and the next run builds
the list again from whatever is attached.

No identifier of any person belongs in that script, in this file, or anywhere
else in the repository. It is written to work for whoever runs it.

Turn the hook on once per clone; nothing else installs it:

    git config core.hooksPath .githooks

`lint.sh` and CI run the same check, because `--no-verify` walks past a hook and
a clone that never installed one is protected by nothing.

If something does get in, it comes out with `git-filter-repo --replace-text`
over every commit, followed by a force-push of every branch and tag. Budget an
afternoon and re-cut any release whose source archive carries it. Search for
fragments as well as whole values: a key survives as its undashed form, and as
the six digits somebody quoted in an assertion.

## Checking notarisation

`xcrun` resolves through whatever `xcode-select` points at. Pointed at the
Command Line Tools, it finds a copy of `notarytool` that cannot read every kind
of stored credential and answers `No Keychain password item found for profile`
for a profile that exists and works. `security find-generic-password` cannot see
those credentials either.

**An error from either is not evidence that notarisation is unconfigured.**
Never answer this question by hand. One script answers it:

    ./scripts/notary-status.sh

It finds a copy of notarytool that can read the credential. Where it cannot
find one it answers `unknown`, not `no`: a copy that cannot read a credential
cannot tell a missing one from one it is unable to see. Treat `unknown` as
unknown, and never report notarisation as missing on the strength of it.

`build-app.sh` prefers Xcode's copy for the same reason, so a release notarises
whatever `xcode-select` is set to.

## Snapshots

`./scripts/snapshots.sh` renders every screen from the built **unbranded** app
and compares it with `tests/snapshots/`. It needs `./build-app.sh` to have run;
`scripts/run-tests.sh` skips it rather than failing when there is no app.

Baselines belong to one branding, the header drawing the app's own name, so
never record them from an official build.

Looking is not recording. A screen under review changes several times before
it is right, and recording after each one rewrites baselines nobody has agreed
to yet. `--look` draws every screen into a temporary directory and leaves the
baselines alone; `--look hu` draws them in one language, which is how to find
out whether a layout survives a longer translation than English or German.

`--record` refuses a change wider than sixteen baselines unless asked with
`--all`. One screen is eight: English at two sizes in two appearances, and one
picture each in German, Arabic, Japanese and Hindi. So more than two screens'
worth means the change was not to a screen but to something every screen has.
That is a real answer sometimes and never an accidental one.

Those four languages are not a sample. They are the four ways a layout breaks
-- text that runs long, an interface that turns round, lines that break without
spaces, and a script taller than its box -- and a fifth language would cost
twenty-seven pictures to prove nothing new.

## Strings

Every string the interface shows has an entry in
`translations/context/strings.json` saying what it means and which screens it
appears on, and the coverage gate fails without one. Adding a string is
therefore three steps: write it, run `./scripts/context-skeleton.py --write`,
and fill in the sentence that explains it. `translations/context/terms.json`
holds the words that are not free to translate and why.

A name, a path or a device identifier interpolated into a translated sentence
goes through `isolated()`. Monospaced text is pinned left to right. Neither
changes anything in English, and both are what stop Arabic and Hebrew coming
out with the pieces in the wrong order.

A capture is taken only once two of them agree. SwiftUI settles over a turn of
the run loop, and an SF Symbol drawn for the first time in a process settles
later still. Captured after a fixed wait instead, the chevron in the drive list
came out drawn in one run and missing in the next, and a baseline disagreed
with itself about once in four runs. If a scene never settles, its picture is
whatever the last turn drew.

`--record` replaces the baselines. It is a separate command because a harness
that updates its own baselines passes whatever it drew. Look at the pictures
before recording.

`ImageRenderer` is not used. It draws SwiftUI by itself and comes back with
the inside of a `ScrollView` empty, which is where the drive list lives. The
scenes are hosted in an off-screen `NSWindow` instead.

`dynamicTypeSize` does nothing on macOS. Every scene rendered at
`.accessibility3` came out byte-identical to `.large`, so the second axis is
window size.

## A Closure Handed To An Objective-C API

Under Swift 6 a closure written inside `@MainActor` code **is** main-actor
isolated, and an Objective-C API that calls it on its own queue traps:
`dispatch_assert_queue_fail`, SIGTRAP, process gone. Under Swift 5 the same
code ran, because nothing checked.

Build 232 crashed on exactly this: `HelperClient`'s XPC error handler, reached
the first time a helper too old to answer sent the call to that handler.

A closure destined for `NSXPCConnection`, `NSWorkspace.recycle`,
`DiskArbitration` or anything else that calls back on an unknown queue must be
created **outside** any actor, in a `nonisolated` function, usually static. Hop
back with `Task { @MainActor in … }` once inside. `HelperClient.roundTrip` and
`moveToTheBin` are the two shapes to copy.

`--check-helper [/dev/diskNsM]` exercises both the reply and the error path
against the real daemon. Without a device it probes the internal disk, which
answers `unknown`, root being unable to read the sealed system partitions, so
that proves the plumbing rather than the identification.

`--reinstall-helper` takes the daemon down and puts it back. The helper has no
KeepAlive and never exits on its own, so **replacing the application leaves the
old helper resident**, answering with whatever methods it was built with. A
hand-installed build then appears to have a broken probe. Sparkle updates do not
need this; hand-installed ones do.

## End-To-End

`./scripts/e2e.sh` drives a whole flow through the built app with no window and
no person: open a container file, unlock it, rebuild the list underneath it,
eject it. Real engine, real helper, real hdiutil. It builds its own LUKS
container once, in a cache of its own, and touches nothing belonging to the
user.

Fixtures are passed as `name=path`. Adding one is a line in `e2e.sh` and a line
in `EndToEnd.swift`, and `check-coverage.sh` fails when a format named in
SPECS.md is built but never handed over. A fixture that is handed over and
missing on disk is a counted failure, not a skipped flow. `openAndChoose` does
the preamble every flow shares: start, scan, open, find the row. It checks each
wait, so a flow reads as the steps it exists for.

`anylinuxfs shell` **truncates an image file to the last byte written**, 320 MB
in and 69 MB out, so a filesystem made that way records one size, later finds
another, and will not mount. `scripts/e2e.sh` puts the length back afterwards.
A fixture built through the engine therefore looks correct and then fails.

`build-app.sh` **runs the tests and refuses to build when they fail**, so
breaking something on purpose to check a test can fail may leave you running
the previous binary and drawing the wrong conclusion. Check the binary's
timestamp changed.

**Check that a new step can fail.** The first version of the rebuild step passed
against a deliberately broken build, because it waited on the phase, which a
rebuild does not change, and asserted against the list as it was before.
`scanGeneration` exists for that: it counts scans actually applied. Break the
thing on purpose and watch the step fail before trusting it.

## The Engine Is Modified

Two of its binaries are built here: `anylinuxfs` and `vmproxy`, built by
`scripts/build-engine.sh` from the source tarball pinned in `vendor/engine.lock`
and checked against the same sha256 the release verifies. Everything else still
comes from the checksummed bottle. The patches are in `patches/`, with what each
does and why.

**Building without that step is fine and produces a working app**, one without
the fixes. `vendor-engine.sh` writes the applied patch names into
`engine/anylinuxfs/PATCHES` and `EnginePaths.enginePatches` reads it, so the app
states what it can do rather than assuming it. Keep it that way.

Needs `brew install llvm lld util-linux` and the
`aarch64-unknown-linux-musl` Rust target.

**The image drivers write now, except VHDX.** VDI, VHD and VMDK (flat and
sparse) are read and written; VHDX and the stream-optimized form of VMDK are
read only. `krun-devices` marks the guest device read-only whenever the driver
reports it cannot be written, so an image that cannot be changed fails to mount
writable rather than failing during a write. The write path is tested against
`qemu-img` in `src/write_tests.rs`, carried by the imago patch: `cargo test` in
the patched crate creates images with qemu-img, writes through the driver, and
has qemu-img convert them back. Those tests skip when qemu-img is absent, so a
green run without it proves nothing. Install qemu first.

**An image can name other files.** From libkrun's header: formats other than raw
can reference other files, which libkrun then opens. Any qcow2 naming a backing
file or an external data file is refused before the engine is told anything;
see `Qcow2Header.namesAnotherFile`. Keep that check ahead of the engine when
adding formats.

## Security Invariants

Each of these is load-bearing. Changing one is a deliberate decision rather
than a refactor.

- The passphrase reaches root through a FIFO. It never appears in `argv`.
- Redaction works by value, so a passphrase is removed from a log because it
  is the passphrase, not because it resembles one.
- The helper accepts parameters and never a command from the app.
- The helper verifies the calling code's signature before doing any work.

## Editing Prose

Documentation in this repository has been edited line by line. Two mistakes
recur when a model edits it:

- Reflowing a paragraph that contains a URL splits the link and breaks it.
  Leave those paragraphs alone.
- A replacement spanning a line break drops the words on the far side of it.
  Match the whole line.

## Versions

`VERSION` is bumped as work lands, not at release time: `patch` for a fix,
`minor` for a feature. Run `./scripts/bump-version.sh minor` once the work is
committed and its tests pass.

The first number is the owner's decision. The script refuses to raise it without
`--approved`, and that flag is not to be used without asking.

Every bump is tagged `v<version>`, so each version is a point in the history
that can be checked out and built. `--no-tag` skips it. Push with
`git push origin main --follow-tags`.

There is no changelog file. git records what changed for anyone working here,
and each release carries its own notes under `releases/<version>.md`, drafted
from the commits by `scripts/release-notes.py`, written with the version by
`bump-version.sh`, and turned into the Sparkle description and the GitHub
release body by `scripts/release.sh`. The draft is a starting point: rewrite it
for the person reading it, then again to take out what they gain nothing from.
The release prints the result and asks somebody to read it before it builds.

## What Is Not A Bug

Properties of the design. Each has been decided, and arriving at one and
"fixing" it undoes a decision rather than a mistake.

- **Encryption nested inside encryption is not opened.** A logical volume that is
  itself a LUKS container fails and the drive falls back to a single volume. It
  should say so rather than look broken. Several containers on one disk are fine.
- **The initialise dialog is only held back while Lukotta is running.** Claiming
  the disk suppresses it, and a claim belongs to a running process.
- **The volume appears as a network drive.** macOS offers no supported way to
  mark an NFS mount local. Only replacing the transport changes it.
- **Full Disk Access cannot be requested.** No API exists; the app detects the
  refusal and explains it.
- **The drive's name in Finder is right from the second unlock onward.** The
  label is not knowable until the volume is open, which is after the share is
  named.
- **A crash with a fallback mount open produces the system's "server connections
  interrupted" dialog.** The crash cannot be intercepted, only avoided by
  unmounting first.
- **Apple Silicon, macOS 15 or later, no Mac App Store.** Sandboxed apps cannot
  read raw devices or elevate.
- **TPM-sealed volumes and detached LUKS headers cannot be opened.**

## What Has Never Run Against A Real Disk

- **The plain-NTFS path.** The first-sector probe recognises three formats and
  there is no unencrypted NTFS drive to hand, so the note saying a drive is not
  encrypted, and opening one with no password, have never run against real
  hardware. Identification is covered both ways by tests over synthetic boot
  sectors, and anything unrecognised is left alone. A gap in the evidence rather
  than a known fault: treat a report against one seriously.
