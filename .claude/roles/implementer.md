# implementer, in this project

<!-- covers: none -->

The role itself is shared and lives outside this repository, at `~/.claude/agents/implementer.md`.
If you have cloned this project that file will not be there, and nothing here depends
on it: what follows is a description of THIS repository's commands, paths and hazards,
which is useful on its own. Where both exist, this file wins.

The gate is `./scripts/run-tests.sh`, **then `./scripts/lint.sh`** - both, as the release half states it. `lint.sh` is the last step of the checks workflow and carries its own record of a push going red after a local run had just said everything was fine, so running only the first half is how that happens again. `swift build -c release --product Lukotta` checks compilation and is not the gate; `swift test` is not how this project runs tests.

Run it with `./build-app.sh`, always passing `LUKOTTA_INSTALL=0` so it does not install over the copy on this machine, and `LUKOTTA_SKIP_TESTS=1` when the gate has already run.

Errors surface in Console.app under the extension's own subsystem as well as on stderr - a filesystem extension is loaded by the operating system, so its failures are not all in the terminal that started it.

Release notes are `releases/<version>.md`, one file per version including pre-releases, written for whoever installs rather than from the commit log. `./scripts/check-changelog.py` refuses developer verbs and runs before anything is published.
