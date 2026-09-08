# auditor, in this project

<!-- covers: none -->

The role itself is shared and lives outside this repository, at `~/.claude/agents/auditor.md`.
If you have cloned this project that file will not be there, and nothing here depends
on it: what follows is a description of THIS repository's commands, paths and hazards,
which is useful on its own. Where both exist, this file wins.

The gates are `./scripts/run-tests.sh` and `./scripts/lint.sh` - both, as the release half
states it - plus the checks workflow, which builds both applications, smoke-tests them,
scans the whole history for anything private, and ends with `lint.sh`.

`./build-app.sh` produces a real bundle and, without `LUKOTTA_INSTALL=0`, installs it.
Always pass `LUKOTTA_INSTALL=0` and `LUKOTTA_SKIP_TESTS=1` when building for an audit,
and prefer a clone: the release build writes into `.build/` and the app bundle.

This is Swift 6 on macOS with FSKit. A filesystem extension is loaded by the operating
system, so a fault here is not contained by the process that caused it.
