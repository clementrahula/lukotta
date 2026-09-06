# designer, in this project

This project's half of the `designer` brief. The role is in the workflow
repository; this file is what it means here.

```
launch:           ./scripts/vendor-engine.sh   (first run only, downloads the
                                                pinned Linux engine)
                  ./build-app.sh
                  then open the built application from dist/
screen:           a macOS window. The app is called Drive Unlocker, not Lukotta:
                  builds are unbranded by default, so the name and icon on
                  screen are the unbranded ones unless the build was made with
                  LUKOTTA_BRANDING=official.
product document: docs/ - the design decisions this project has already made
notepads:         docs/notepads/
```

**On the `v2-coverage` branch**, which is the same repository in another
worktree, the launch is `LUKOTTA_BRANDING=v2 ./build-app.sh`. It produces
"Lukotta v2" under its own identifier, with its own saved passphrases, its own
engine home and its own feed, so nothing judged there can be confused with the
release or the beta. Automatic update checks are off on that line: a build that
updated itself would replace what is being looked at, halfway through looking
at it.

`swift build` is not a launch. It succeeds and produces an app that cannot
unlock anything: a working bundle needs the vendored Linux engine and the
compiled asset catalogue, and `build-app.sh` is what assembles both.
`build-app.sh` needs `actool` from Xcode - without it the app has no icon and no
mark, which looks like a design fault and is a build fault.

## What this project has already been caught by

Two faults reached a release that launching the app once would have found.
Neither was found by a snapshot. So, before calling any change to the interface
judged:

1. **Reach the change the way somebody would**, from a cold start.
2. **Then try every other way of reaching it, and every way of leaving it.**
   For anything shown once: quit, launch again, and confirm it is not shown
   again. For anything with a button: press each button, and close it without
   pressing any. For anything conditional: reach it by each condition.
3. **Leave and come back.** A great deal of what breaks is state written to the
   wrong place, or not written before the process ended.
4. **Say which of these were actually run.** "Tested" without saying what was
   done means a snapshot was looked at.

A snapshot proves a scene draws. It proves nothing about when the scene appears,
when it goes, or what it leaves behind, and those are where the faults are.

Building takes minutes rather than seconds, so judge as much as possible from
one build rather than rebuilding between observations.
