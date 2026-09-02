<!--
One concern per pull request. First time here? CONTRIBUTING.md says what tends
to land and what tends not to.
-->

## What this changes, and why

<!-- The diff says what. This is for why, and for anything that would surprise
     a reader. -->

## What you ran it against

<!-- Which drive, which image, which macOS.
     Nothing to run it against? ./scripts/make-test-volumes.sh builds some. -->

- [ ] `./scripts/run-tests.sh` passes
- [ ] `./scripts/lint.sh` passes
- [ ] If it touches mounting, a format or the privileged helper, I have said
      above what I opened it with
- [ ] If it touches the copy path or a filesystem, I ran at least one of the
      hardware harnesses in CONTRIBUTING.md and quoted the numbers above

## Anything else

<!-- A format change also changes SPECS.md. A new string means thirty-six
     languages are short one and its context entry is missing, both of which
     lint.sh will tell you. Nothing to add here is fine; delete the section. -->
