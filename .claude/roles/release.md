# release, in this project

This project's half of the `release` brief. The role is in the workflow
repository; this file is what it means here.

```
artefacts:            dist/<slug>.dmg, dist/<slug>-<version>.zip, the delta
                      updates built beside them, dist/appcast.xml (or
                      dist/appcast-beta.xml on the beta channel), and dist/notes
channel:              Sparkle feed at https://updates.lukotta.com/appcast.xml,
                      beta at https://updates.lukotta.com/beta/appcast.xml;
                      a GitHub release on clementrahula/lukotta; and the
                      Homebrew cask clementrahula/tap/lukotta (lukotta@beta on
                      the beta channel)
publish:              LUKOTTA_PUBLISH=1 ./scripts/release.sh
                      LUKOTTA_CHANNEL=beta LUKOTTA_PUBLISH=1 ./scripts/release.sh
verify from outside:  curl -fsS https://updates.lukotta.com/appcast.xml \
                        | grep -oE 'sparkle:shortVersionString>[^<]*' | head -1
                      curl -fsIL https://github.com/clementrahula/lukotta/releases/latest/download/Lukotta.dmg \
                        | grep -iE '^HTTP|^content-length' | tail -2
gate:                 ./scripts/run-tests.sh, then ./scripts/lint.sh
```

Both verify commands were run against the live feed and the live download and
returned the published version and a 200 with a real content length. They read
what a person receives, not what the upload reported sending.

## What is not finished when the script exits

`scripts/release.sh` builds, notarises, signs and describes the release. Two
things it can only tell you to do, because they are commits in other
repositories:

- **The appcast feed.** Commit and push the checkout the appcast was written
  into, so it is served at the feed URL. Where no feed checkout was given, the
  script prints the clone command and the `LUKOTTA_APPCAST=` invocation to
  repeat with. Until that push lands, the release exists and nobody is offered
  it.
- **The Homebrew cask.** Commit and push the tap so the cask is installable.

A release is not complete while either is outstanding, and a run that stops
between them is exactly the half-published state the role exists to prevent.
Say which of the two are done.

## Things this project has already been caught by

- **The build number is the commit count, and it must exceed the published
  one.** Sparkle offers an update only on a higher build number. A hotfix cut
  from a shorter branch, a squash merge or a rewrite produces a number already
  released, and Sparkle then answers "up to date" to everybody for a release
  that fixes something. The script checks this against the published feed
  rather than trusting it; do not work around that check.
- **Release notes are tied to the words they shipped with.** `releases/APPROVED`
  must name the version beside the hash of `releases/<version>.md` as it stands,
  or the script refuses. It stops a release going out under notes edited after
  they were written. Write the line and carry on - it is a record, not a gate to
  wait behind.
- **The beta channel is not gated.** Publish to it freely.
- **Branding is opt-in.** Builds are unbranded by default because the name and
  logo are trademarks the GPL does not cover. `LUKOTTA_BRANDING=official` is
  what `scripts/release.sh` uses, and nothing else should.
- **What the feed reports, not the last tag.** Versions get tagged here without
  ever being released; three have been. The notes describe everything the people
  receiving the update have not seen.
