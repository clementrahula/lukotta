# auditor, in this project

<!-- covers: none -->

The role itself is shared: `~/.claude/agents/auditor.md`, from the workflow repository.
This file is the part that is only true here, and it wins where the two disagree.

The gates are `./scripts/run-tests.sh` and `./scripts/lint.sh` - both, as the release half
states it - plus the checks workflow, which builds both applications, smoke-tests them,
scans the whole history for anything private, and ends with `lint.sh`.

`./build-app.sh` produces a real bundle and, without `LUKOTTA_INSTALL=0`, installs it.
Always pass `LUKOTTA_INSTALL=0` and `LUKOTTA_SKIP_TESTS=1` when building for an audit,
and prefer a clone: the release build writes into `.build/` and the app bundle.

This is Swift 6 on macOS with FSKit. A filesystem extension is loaded by the operating
system, so a fault here is not contained by the process that caused it.
