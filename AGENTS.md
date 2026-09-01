# Notes for Coding Agents

This file lists the things about Lukotta that mislead: commands that report the
wrong thing, conventions that differ from the default, and rules that look like
details and are not.

[CONTRIBUTING.md](CONTRIBUTING.md) covers house style and how to submit work.
[BUILDING.md](BUILDING.md) covers requirements, switches, and signing. Read
those for everything this file leaves out.

## Commands That Report the Wrong Thing

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

Four ways of watching a copy that each lie in their own direction, all of them
hit while measuring one:

- **`du -sm` on the destination.** It counts allocated blocks and went on
  climbing for minutes after a copy had frozen. Sum `find -printf '%s'` instead.
- **`find -printf '%s'` as a liveness probe.** It stats every file including the
  one being written, so it can block on that file alone -- a `find` that times
  out is not evidence the mount stalled. Ask `stat` about the directory, and
  time it.
- **`nfsstat` on a wedged mount.** It blocks too, so bound it and treat its own
  hanging as the signal rather than waiting for an answer that is not coming.
- **`ls` output in a shell where `ls` is `eza`.** The columns differ, so
  `awk '{print $5}'` silently sums zero. Use `find -printf` or `stat`.
- **`grep -c` where the count is zero.** It prints `0` and exits non-zero, so
  `$(grep -c … || echo 0)` prints two zeros.
- **The NFS unresponsive flag as a stall detector.** Polled every two seconds
  through a whole copy it was never seen raised, while timing a plain `stat` on
  the same mount found six requests over five seconds and a worst of 8.9. It
  answers from client state that does not reflect what the clock catches. Time
  the request; the flag is a verdict about latency, not a measure of it.

The shape is the same every time and is worth stating on its own: **a probe
that cannot take a reading must say so, not return zero.** Each of these
returned a plausible number instead of failing -- `0 MiB` for a listing that
timed out, `0` episodes for a flag never sampled at the right instant, five
megabytes for a machine holding five hundred -- and a plausible wrong number is
believed, acted on, and sends an afternoon after the wrong fault. Bound every
call that can block, and distinguish "measured zero" from "could not measure".

## Layout

Sources are in `sources/`, lowercase, and every target in `Package.swift`
carries an explicit `path:`. The conventional `Sources/` fails on a
case-sensitive volume.

## Which Channel Work Goes To

**Beta, unless the owner has said otherwise.** The release channel is settled
and is not published to without them asking for it.

`scripts/release.sh` enforces the second half of that: a release build is
refused unless `releases/APPROVED` names the version and the line beside it is
the hash of `releases/<version>.md` as it stands. Approval is therefore about
one version and one set of words, cannot be given in advance, cannot be carried
over, and does not survive the notes being edited afterwards. The script prints
the notes and the line to add when it refuses.

The beta channel is not gated. Publish to it freely.

## Version Numbering

`VERSION` holds the version being worked towards, as plain semver: `1.20.1`.
Nothing else goes in it.

A beta of that version is `1.20.1-beta.1`, then `-beta.2`, and the release it
leads to is `1.20.1` with nothing after it. **The suffix is not written into
`VERSION`** — `scripts/release.sh` adds it when the channel is `beta`, and
numbers it from the beta feed rather than from a file, so it cannot disagree
with what has actually been published. The tag is the version with a `v` in
front: `v1.20.1-beta.1`, `v1.20.1`.

Both channels used to carry the same number, so "1.20.1" meant two different
builds depending on which app you were holding. Semver orders the pre-releases
correctly and says which is which out loud.

Neither Sparkle nor Homebrew minds. Sparkle decides what is newer from
`sparkle:version`, which is the commit count and never the display string;
`CFBundleShortVersionString` is shown and not compared. A cask takes the
version as written and its tag is now `v#{version}` on both channels.

Written where somebody reads it: the About sheet says the version with the
build in brackets after it, `1.20.1-beta.1 (612)`.

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

## Finding Out What the App Did

Everything is logged with `os.Logger` under the running bundle's identifier,
which `Log.subsystem` is the only definition of. To read it back:

    log show --predicate 'subsystem == "com.lukotta"' --last 30m

An unbranded build logs under `com.example.driveunlocker`, and the privileged
helper logs under the same subsystem as the app it came from, so one predicate
catches both processes and the `category` tells them apart.

A string interpolated into a log message is private by default and reads back
as `<private>`, which is correct for a drive's name and for a path on someone's
disk. Anything meant to be legible says `privacy: .public`. A passphrase is
never logged.

## Every Source File Says What It Is Under

Two lines at the top of each Swift, shell and Python file:

    // SPDX-License-Identifier: GPL-3.0-or-later
    // Copyright (C) 2026 Clement Rahula

After the shebang where there is one, and after `swift-tools-version` in the
package manifest, since both have to come first. Files under `patches/` belong
to other projects and carry those projects' identifiers instead: MIT for
imago, Apache-2.0 for krun-devices, GPL-3.0-or-later for anylinuxfs.

The grant itself is in README's licence section, in full, because "GPL-3.0-or-
later" is a shorthand for a sentence somebody has to have written.

## Fixtures Are Invented, Never Captured

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

## Checking Notarisation

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

## A Closure Handed to an Objective-C API

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

## End-to-End

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

## Invariants Worth Keeping

Each of these was a fault before it was a rule, and none of them is obvious from
the code alone. Changing one needs the evidence that established it.

- **A drive is open only where something is mounted.** The engine makes the
  mount point before it mounts on it and leaves the directory behind when the
  mount fails, so a path that exists is no evidence. Only the mount table
  counts, on every route.
- **A mount of this app's own is `.local:/mnt/…` or `.local:/run/…`.** A volume
  group is served as a tmpfs under `/run` with the volumes bound inside it.
  Recognising only the first shape meant the sweep for engines serving nothing
  would have taken down the machine serving somebody's root and home.
- **The kept-aside copy is filed under the identifier.** The app writes it and
  the shim puts it back, so a disagreement about where is a rollback that never
  happens. `AppRollback.supportName` is the one answer; `bundle_identifier()` in
  `sources/LukottaLaunch/main.c` does the same for the shim.
- **The copy is made when the archive arrives, not when it installs.** Sparkle
  sends `didDownloadUpdate` and `didExtractUpdate`, and does not send
  `willInstallUpdate`. A copy hung on that one is never made.
- **A copy of the running version is armed, not spent.** It is dropped only
  when it is of some *other* version, which is proof the swap already happened.
  Between a download and the quit that installs it -- and Sparkle resumes an
  extracted update a session later without downloading it again -- the copy is
  of what is running, and dropping it there disarms the install it was made
  for. `--smoke-test` runs this path too.
- **The machinery slipping is not the drive refusing.** A broken pipe, a locked
  image, an NFS mount macOS would not make: absorbed and retried, never
  reported. A wrong passphrase or an unreadable filesystem is an answer and is
  reported at once. `TransientFailure` holds the list.
- **An attempt has an end, on every route.** Eight minutes, then what it started
  is taken down. No real drive needs it and a stuck one would otherwise wait for
  ever. The mount script ends itself a little sooner than that, because ending a
  privileged attempt from outside reaches the shell and not the root engine
  under it -- which went on mounting, and produced a drive in Finder minutes
  after somebody had been told it could not be opened.
- **A sweep takes down only what this app can show is its own, and says what
  really came down.** A mount point it wrote down when it made it, or one under
  this user's `~/Volumes`. A probe that could not be started is not a mount that
  has stopped answering, and one silence is not two. Reporting a forced unmount
  that did not happen is what sent the sweep on to take down engines still
  serving it.

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

## Translating a Changelog

The release channel only. A pre-release's notes stay in English: a beta goes
out often and to few people, and translating it every time is work out of
proportion to that. This is a decision, not an omission -- do not "fix" it.

The order matters, and each step exists because doing it earlier wastes the
one after it.

1. **The English is written and cut back.** `releases/<version>.md`, one
   bullet a line.
2. **The owner de-slops it and approves it**, which means a line in
   `releases/APPROVED` naming the version and the hash of those exact words.
   Nothing is translated before this. A draft made against notes that then
   change is thirty-six drafts thrown away.
3. **Draft the translations** into `releases/notes/<version>/<lang>.md`, same
   bullet-a-line shape. First line is `<!-- heading: … -->`, that language's
   word for "Version"; without it an English heading sits over a translated
   list.
4. **Build the pack**: `./scripts/notes-audit.py <version> --zip`. It carries
   the approved English, the drafts, and the glossary built from
   `translations/context/terms.json`. It carries no earlier releases on
   purpose -- a term that must stay consistent between versions belongs in the
   glossary, and if it is not there, that is the thing to fix.
5. **The owner audits it in a different model** and brings back review notes.
   The result is advisory: it proposes, it does not decide. Every proposal
   carries its reason, and one without a reason is discarded, because a change
   nobody can weigh is a change nobody can accept.
6. **Apply what survives**, read against the translation already there, and
   release. `release.sh` finds the files, writes a page per language, and
   names each one in the appcast with its `xml:lang`. A language nobody wrote
   is absent and gets the English notes.

A release with no translations still goes out; `release.sh` says so every time
rather than refusing. A gate that blocks a fix is a gate somebody learns to
work around.

## When to Bump

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

## What the Runs Are For

Three, and they answer different questions.

| Run | What it answers | How long |
| --- | --- | --- |
| `scripts/run-tests.sh` | Does the logic hold, on any Mac, with no drive | seconds |
| `scripts/preflight.sh` | Does a release work: install, open, write, eject, update, roll back, both channels | half an hour |
| `scripts/e2e.sh` | Everything: every format, every filesystem, the awkward names, the unhappy paths | over an hour, per channel |

`e2e.sh` builds its own fixtures the first time and keeps them in
`~/Library/Caches/dev.lukotta.e2e`. One of them is made with Homebrew's
`mke2fs`, fetched if it is missing: the guest carries mkfs for btrfs, NTFS and
FAT only. The LUKS layouts, including a volume group of three volumes, come from
`scripts/make-test-volumes.sh`, and a Mac without them tests one shape fewer and
says so rather than passing quietly.

`update-test.sh` is inside `preflight.sh` and can be run alone. It applies real
updates through Sparkle against a feed served from this Mac: a full archive, a
delta, one offered while a drive is open, and a build that cannot start being
put back.

## What Is Not a Bug

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
- **A symbolic link whose target holds a slash and a character outside ASCII
  cannot be made, and one that exists cannot be followed.** The `nfc` mount
  option does it, the same volume mounted without it is fine, and the end-to-end
  run asserts both halves so that a change underneath is noticed. SPECS.md §5
  has the reasoning.

## Opening a Real Drive Without a Person

`--drive` on a DEVTOOLS build opens and closes a physical drive from a shell,
with no window and nobody clicking:

    "/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev" --drive open=/dev/disk4s1
    …                                                          --drive open=/dev/disk4s1 read-only
    …                                                          --drive eject=/dev/disk4s1

It uses the saved Keychain key, so nothing is typed. Two things about it are
not obvious and both cost time to find:

- **`DEVTOOLS` is off for a branded build.** `build-app.sh` compiles the
  harnesses into an *unbranded* build only, unless `LUKOTTA_DEVTOOLS=1` is
  passed. `LUKOTTA_BRANDING=dev ./build-app.sh` produces an app with no
  `--drive`, no `--e2e` and no `--snapshots`, and the flag is simply ignored
  with no complaint. Build test copies with
  `LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=dev ./build-app.sh`.
- **The daemon lives in the app bundle, not in PrivilegedHelperTools.** It is
  registered with `SMAppService` and runs from
  `Contents/MacOS/Lukotta<Brand>Helper`. `/Library/PrivilegedHelperTools` holds
  daemons from the older install route and may be months stale while a current
  one is running from a bundle. **The daemon carries `MountScript`**, so a
  change to the mount options or a generated action does nothing until the app
  is reinstalled and the daemon replaces itself -- reading the app binary and
  finding the change there proves nothing.

  Until it was fixed, a daemon of this kind was never replaced at all.
  `installedToolIsStale` returns false the moment there is no job in
  `/Library`, so the only signal left was the hand-raised contract number, and
  a rebuilt app went on being served by the daemon it was built to replace. The
  build the daemon reports is compared now, so a rebuild is enough. `--drive`
  waits for the process id to change and refuses to mount if it does not:

      the running daemon is older than this build; replacing it
      replaced; the daemon is now this build's

  Confirm it from the outside as well -- `ps -eo pid,lstart` on the daemon
  before and after -- and confirm the change itself from the guest's own line
  in the transcript, `Running before_mount action: ...`, rather than from the
  config file, which is merged and can keep an older section.

`config.toml` is also worth checking rather than assuming. The generated
actions are merged into whatever is already in it, so a section written by an
older daemon can survive a reinstall and keep being used; the engine's command
line names the action it ran, and the file says what that action does.

## The Drive These Faults Appear On Is Nearly Full

Every timing measurement here was taken against a USB stick at 92% to 96%
full, and that is not incidental. NTFS allocation slows as free space
fragments, and a thirteen-gigabyte copy into twelve gigabytes of headroom is
the hardest thing the app is asked to do. Two things follow.

The numbers do not transfer to an empty drive, and an empty drive is not
evidence that a fault is gone. Sampled through a copy, the stick was completely
idle in 119 of 178 one-second samples with a p90 of 12 MB/s and a peak of 18:
what looks like a slow device is mostly a device doing nothing, waiting on
something else.

And each run has to clean up after itself. Thirteen gigabytes twice does not
fit, and a second run started without removing the first fails on ENOSPC --
which reads exactly like the fault being investigated and is not it.

## The Engine Cannot Be Restarted on a Real Drive Without the App

`/dev/diskNsM` is `root:operator` mode 640 and the account here is not in
`operator`, so the engine cannot open a physical drive by itself. The running
one was handed the device by the privileged helper, and only the app can ask
the helper for that. Killing the engine and starting it again from a shell --
to change `ram_size_mib`, the thread count, or a `before_mount` action -- gets

    macOS: Error: Cannot probe /dev/diskNsM: LibErr(0); Insufficient permissions?

So any experiment that needs a different machine configuration on a real drive
needs the drive reopened through the app -- which is what `--drive` above is
for, and it needs no person. Container
files have no such problem: the engine opens a file the user owns unprivileged,
and the machine can be restarted as often as a question needs. Put anything
that varies the guest's configuration on an image, and keep the real drive for
what only a real drive can answer -- which is timing, because an image on the
internal disk is two orders of magnitude faster than the USB stick these faults
appear on.

## What Has Never Run Against a Real Disk

- **The plain-NTFS path.** The first-sector probe recognises three formats and
  there is no unencrypted NTFS drive to hand, so the note saying a drive is not
  encrypted, and opening one with no password, have never run against real
  hardware. Identification is covered both ways by tests over synthetic boot
  sectors, and anything unrecognised is left alone. A gap in the evidence rather
  than a known fault: treat a report against one seriously.
- **The privileged route.** Every fixture is a container file, which opens
  unprivileged, so nothing in the harnesses has ever gone through `osascript`
  with an administrator password or through the daemon. The deadline the daemon
  keeps, the script's own deadline, and the daemon's unmount lent to the sweep
  are all on that route. Their unprivileged twins are exercised on every run,
  and the shell the deadline is built from is covered by a test of its own --
  but the route itself waits on a drive nobody here has.

## The NFS Mount Options Are Not What This Code Asks For

Every mount goes through the vendored engine, and the engine merges its own
defaults over whatever `MountScript.nfsOptions` supplies. The merge is a
`BTreeMap` keyed by option name (`anylinuxfs`, `fsutil.rs`, `NfsOptions::
default`, and `cmd_mount.rs` calls `.extend`), so supplying a key replaces the
engine's value and supplying a *different* key sits beside it. Three
consequences, each of which has already misled somebody:

- **The mount is soft, always -- but not because `hard` cannot be asked for.**
  The engine adds `soft,intr,timeo=100,retrans=3`. A comment here once argued
  at length that this was a hard mount because it had not asked for a soft one,
  and an audit that flagged the missing `timeo` was answered from that belief.
  Not asking for an option is not the same as choosing its opposite.

  This section also said `soft` could not be removed by passing `hard`, being a
  second key rather than a replacement. Both keys do reach the command, and
  mount_nfs takes the last of the pair: mounting the same server by hand with
  `soft,intr,nolocks,hard` reports current parameters saying `hard`, with no
  `soft` among them, and ours land last. It stays soft by choice, because it is
  there to stop a kernel panic when a drive is pulled without unmounting, and
  that claim has not been tested anywhere it would be safe to be wrong.
- **`timeo` does nothing on its own.** It sets the *initial* retransmit
  timeout, and the dynamic estimator -- on unless `dumbtimer` says otherwise --
  replaces it with an interval learned from observed round trips, which on a
  virtio link is milliseconds. mount_nfs(8) says so under `timeo`: "Normally,
  the dumbtimer option should be specified when using this option to manually
  tune the timeout interval." A mount carrying `timeo=600` and `nodumbtimer`
  never waited sixty seconds for anything, and three separate runs raised the
  number, watched a copy fail anyway, and concluded the timeout was innocent.
  Check `nfsstat -m` for `dumbtimer` before believing any timeout in the table.
- **`rsize`/`wsize` are asked for at 1 MiB and granted at 128 KiB.** `nfsstat
  -m` prints both: "original mount options" is the request, "current mount
  parameters" is what is in force. Any argument about transfer size should be
  made from the second.
- **`deadtimeout` decides whether a slow drive survives.** See below.

Read a real mount before reasoning about any of this. The engine logs the exact
command it ran, under `~/Library/Application Support/<bundle id>/engine/Library/
Logs/anylinuxfs-*.log`.

## Why a Copy to a Slow Drive Used to Die

A drive that goes quiet -- shingled media reorganising, an enclosure stalling, a
Mac whose disk is saturated -- stops answering NFS for far longer than it takes
macOS to give up on it. At `deadtimeout=45` the client marks the mount dead and
unmounts it; the engine watches its own share, sees it go, and shuts the microVM
down. The copy ends there and cannot resume. From the outside it looks like a
freeze: writes at zero, `df` still answering out of the client's cache, and a
progress bar that never moves again.

`deadtimeout=300` is the fix, and it is a balance rather than a maximum.
Removing the option entirely is worse: a mount that loses its server then never
recovers at all.

Reproducing it needs a volume large enough to build a real dirty backlog in the
guest -- the 64 MB fixtures cannot, and neither can 252 MB. On a 40 GB NTFS
volume with the host disk deliberately saturated, the behaviour is reliable:

    deadtimeout=45    unmounted within 90 seconds, every run
    deadtimeout=300   mounted throughout ten minutes, still writing, back to
                      full speed once the load lifts

**Making a large test volume needs no password.** The engine fails with `start
vm error: Invalid argument (errno 22)` when run from a shell, with or without
`sudo`, because it is missing `ANYLINUXFS_HOME` -- which the app sets and a bare
invocation does not. Set it and the guest shell works unprivileged:

    export ANYLINUXFS_HOME="$HOME/Library/Application Support/com.lukotta/engine"
    dd if=/dev/zero of=big.img bs=1m count=0 seek=40960
    "$ENGINE" shell big.img -c "mkfs.ntfs -f -F -L BIG /dev/vda"

The guest truncates the image to the last byte written, so restore its length
afterwards. Saturate the host disk with a dozen `dd` writers to starve the
backing store; that is what turns a working mount into the failure above.

## Silence Is Not Evidence That a Mount Is Gone

Three places used to act on a question that had not been answered, and each of
them force-unmounts:

- `EngineStatus.current()` returned an empty list when the engine could not be
  asked, could not be run, exited non-zero, or outlived its deadline -- the same
  answer it gives when the engine replies that nothing is mounted. `stale()`
  then read every live mount as abandoned. Use `currentIfAnswered()`, which
  returns nil for all four, and never act destructively without an answer.
- `deadEngineMounts` called a mount dead after two silent probes a second apart.
  A microVM frozen by a busy Mac was measured silent for forty seconds and came
  back serving its drive. It now needs a minute of silence, and refuses outright
  while any microVM is still running -- `serving()`, which matches the `mount`
  process and deliberately not `gvproxy`, since gvproxy outlives a failed mount
  and is what the sweep exists to clear.
- A mount point left behind after a mount vanishes is an ordinary directory on
  the startup disk, and a copy still running writes into it and succeeds. Those
  are reported and never swept; only empty ones are removed.

## What "No Route to Host" Over vmnet Actually Meant

The engine can serve its NFS over gvproxy, a user-space TCP/IP stack, or over
vmnet, the framework macOS itself uses. vmnet is much faster -- two and a half
times the write throughput, measured -- and every attempt to use it ended at

    macOS: Checking NFS server on 172.27.1.2:2049...
    macOS: Error connecting to port 2049: No route to host (os error 65)

with a guest that was plainly fine: `eth0` up, addressed, routed, the drive
mounted, `nfsd` listening, and the host answering its pings in 0.13 ms. Four
separate causes, each of which fully explained the symptom on its own.

**The build script.** `vmnet-helper` ships signed with
`com.apple.security.virtualization`. Re-signing it without one takes that away,
after which it fails with `VMNET_FAILURE` and prints nothing at all, which the
engine reports as a config it could not parse. `init-rootfs` had no entitlements
either, so any rebuild of the Linux image died with `start vm error: Invalid
argument (errno 22)` -- which reads like a bad argument, not a missing
entitlement, and cost three attempts at `sudo` once already.

**The MAC address.** vmnet assigns one and reports it; the engine gave the guest
a random one instead. Broadcast reaches a guest wearing the wrong address, so
ARP was answered and the host learned a neighbour it could never talk to.

**Announcing.** vmnet forwards to a guest it has heard from. A guest that only
listens is never heard from, and its ARP entry on the host stays `(incomplete)`.

**Stale helpers, which is the one that wasted the day.** A `vmnet-helper` left
running from an earlier attempt keeps its `bridge100` and its subnet. The next
run picks the same subnet, macOS routes to the *old* bridge, and everything
above is invisible behind a failure that looks identical to the three real ones.
Kill every `anylinuxfs mount` and `libexec/vmnet-helper` and wait for the bridge
to disappear between runs, or measure nothing.

Useful ground truth, in order of how much it settles:

- `/proc/net/snmp` in the guest. `Icmp: InEchos` and `Tcp: InSegs` say whether
  the frames arrived at all, which `ping` on the host cannot.
- `ifconfig bridge100` -- the address cache says which MAC vmnet has learned on
  `vmenet0`, and `arp -an` says which one the host is sending to. They must
  agree, and comparing them across two different runs proves nothing.
- A socket client of your own on the helper's socket, answering ARP and ICMP in
  thirty lines of Python, takes libkrun out of the picture entirely. That is
  what showed the frames were arriving from vmnet and being lost afterwards.
- `tcpdump` is not available: `/dev/bpf*` is root-only here, and asking for a
  password is not allowed.

## A Branded Build Is Not Copied Into /Applications

`Lukotta.app` and `Lukotta Beta.app` on this Mac are the copies being used, and
they change only when the updater inside them updates them. A release is built,
signed, notarised and pushed to GitHub; that is the whole of it. Copying it into
`/Applications` destroys the version there was to update from, which has
happened to a beta in the middle of testing that very update.

So `build-app.sh` builds a branded app and does not copy it. It says nothing
about this and fails at nothing -- the step simply does not apply.

`dev` and `unbranded` still install: "Lukotta Dev" under `com.lukotta.dev` and
"Drive Unlocker" under `com.example.driveunlocker`, each with its own daemon and
its own saved passphrases, neither able to reach the two above. An earlier
version of this guard blocked those too and printed a refusal, which broke the
plain `./build-app.sh` in CONTRIBUTING and protected nothing.

A first install of either channel comes from the disk image or the Homebrew cask
`scripts/release.sh` produces:

    brew install --cask clementrahula/tap/lukotta
    brew install --cask clementrahula/tap/lukotta@beta

That is what everybody else installs, so it is the thing worth testing.
`scripts/update-test.sh` is the one script that may replace an installed app,
because driving Sparkle against the installed pre-release *is* the update
mechanism, and it keeps a copy of what was there and puts it back.

`check-coverage.sh` holds all of it: that `build-app.sh` copies neither branded
build, that `release.sh` passes `LUKOTTA_INSTALL=0` and writes nothing into
`/Applications`, and that no other script copies over an installed app.
