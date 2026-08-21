# Notes for Coding Agents

This file lists the things about Lukotta that are misleading — commands that
report the wrong thing, conventions that differ from the default, and rules
that look like details and are not.

[CONTRIBUTING.md](CONTRIBUTING.md) covers house style and how to submit work.
[BUILDING.md](BUILDING.md) covers requirements, switches, and signing. Read
those for everything this file leaves out.

## Commands That Report The Wrong Thing

`swift test` prints `no tests found`. There are 178 checks; they are a plain
executable target, run by `./scripts/run-tests.sh`. Never conclude from
`swift test` that this project is untested.

`swift build` succeeds and produces an app that cannot unlock anything. A
working bundle needs the Linux engine and the compiled asset catalogue:

```bash
./scripts/vendor-engine.sh    # downloads the pinned engine on first run
./build-app.sh
```

The app it builds is called **Drive Unlocker**, not Lukotta. Builds are
unbranded by default because the name and logo are trademarks that the GPL does
not cover; `LUKOTTA_BRANDING=official` is what `scripts/release.sh` uses. Do not
change that default, and do not hard-code either identity in Swift — the code
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
`MountScript.mountedCheck` does. Trusting the exit status silently disables
every fallback path in the generated script.

`MountScript` lives in `LukottaCore`, which the privileged helper links.
After changing it, restart the helper or you are testing the old script.

The engine is driven through a pty by `expect`, so its output arrives with
carriage returns. Strip `\r` before parsing or comparing.

The generated script embeds a single-quoted `awk` program. An apostrophe
anywhere inside it — including in a comment — closes the quote and breaks the
whole script. A test runs `sh -n` over the generated output to catch this.
Keep it.

## Finding Out What The App Did

Everything is logged with `os.Logger` under the running bundle's identifier,
which `Log.subsystem` is the only definition of. To read it back:

    log show --predicate 'subsystem == "com.clementrahula.lukotta"' --last 30m

An unbranded build logs under `com.example.driveunlocker`, and the privileged
helper logs under the same subsystem as the app it came from — one predicate
catches both processes, and the `category` tells them apart.

A string interpolated into a log message is private by default and reads back
as `<private>`, which is what a drive's name and a path on someone's disk
should do. Anything meant to be legible says `privacy: .public`. A passphrase
is never logged at all.

## Security Invariants

These are load-bearing. Changing any of them needs a deliberate decision, not
a refactor.

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
