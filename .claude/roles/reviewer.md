# reviewer, in this project

<!-- covers: none -->

The role itself is shared: `~/.claude/agents/reviewer.md`, from the workflow repository.
This file is the part that is only true here, and it wins where the two disagree.

The gate is `./scripts/run-tests.sh`. `swift build -c release --product Lukotta` checks
that it compiles and is not the gate; `swift test` is not how this project runs its
tests.

CI additionally builds both shipped applications through `./build-app.sh` with
`LUKOTTA_INSTALL=0 LUKOTTA_SKIP_TESTS=1` and both branding values, smoke-tests them, and
runs a privacy check over the whole history. A change to the build or to branding is not
covered by the unit gate alone.

The request host is **github**. This project has no changelog file at its root; if a
change needs one, ask rather than assuming a path.
