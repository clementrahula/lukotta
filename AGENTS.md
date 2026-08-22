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

Run `./scripts/lint.sh` before committing.

## Layout

Sources are in `sources/`, lowercase, and every target in `Package.swift`
carries an explicit `path:`. The conventional `Sources/` fails on a
case-sensitive volume.

The build number is the git commit count. Rebuilding without committing
reuses the previous number, so two different binaries claim the same build.
Commit before building anything you intend to compare.

## The Engine

**The engine exits 0 when a mount fails.** Its status describes its own
shutdown. Judge a mount by the mount table, which is what
`MountScript.mountedCheck` does. Trusting the exit status disables every fallback path in the generated
script.

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

## Snapshots

`./scripts/snapshots.sh` renders every screen from the built **unbranded** app
and compares it with `tests/snapshots/`. It needs `./build-app.sh` to have run;
`scripts/run-tests.sh` skips it rather than failing when there is no app.

Baselines belong to one branding, the header drawing the app's own name, so
never record them from an official build.

`--record` replaces the baselines. It is a separate command because a harness
that updates its own baselines passes whatever it drew. Look at the pictures
before recording.

`ImageRenderer` is not used. It draws SwiftUI on its own and comes back with
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
green run without it proves nothing — `brew install qemu` first.

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
and each release will carry its own notes under `releases/<version>.md`, which
`scripts/release.sh` turns into the Sparkle description and GitHub shows on the
release page.
