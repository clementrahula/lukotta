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
