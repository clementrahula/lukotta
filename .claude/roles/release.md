# release, in this project

<!-- covers: scripts/ship.sh, scripts/release.sh, scripts/prove-beta.sh, scripts/beta-proven.sh, build-app.sh checked: 2026-09-11 -->

This project's half of the `release` brief. The role itself lives outside this
repository; if you have cloned this project it will not be here, and nothing below
depends on it - what follows describes THIS repository and stands on its own.

```
artefacts:            dist/<slug>.dmg, dist/<slug>-<version>.zip, the delta
                      updates built beside them, the appcast, the release notes,
                      and SHA256SUMS.txt
channel:              Sparkle feed at https://updates.lukotta.com/appcast.xml,
                      beta at https://updates.lukotta.com/beta/appcast.xml;
                      a GitHub release on clementrahula/lukotta; and the
                      Homebrew cask clementrahula/tap/lukotta (lukotta@beta on
                      the beta channel)
publish:              ./scripts/ship.sh              a beta
                      ./scripts/ship.sh release      the release channel
verify from outside:  ship.sh does it - it fetches the live feed after
                      publishing and checks what the file says. By hand:
                      curl -fsS https://updates.lukotta.com/appcast.xml \
                        | grep -oE 'sparkle:shortVersionString>[^<]*' | head -1
                      curl -fsIL https://github.com/clementrahula/lukotta/releases/latest/download/Lukotta.dmg \
                        | grep -iE '^HTTP|^content-length' | tail -2
gate:                 ./scripts/run-tests.sh, then ./scripts/lint.sh.
                      ./scripts/preflight.sh is what a release actually needs -
                      install, open, write, eject, update, roll back, both
                      channels - and takes about half an hour.
release gate:         ./scripts/prove-beta.sh <beta> <bitlocker partition> <ntfs volume>
                      on the published beta; ship.sh release refuses without it
```

## One command, and running it is the decision

`ship.sh` is the whole act: it runs every check first, before anything is
compiled, then builds, publishes, and finishes. It moves the tag, marks the
notes read, refuses on an uncommitted file while saying which, leaves no GitHub
release as a draft, and commits and pushes the appcast and cask checkouts itself.

Each of those was once a manual step, and each one stopped a release that was
otherwise ready - reported at the end of a long build, so the next attempt was
another long build. Do not reassemble that sequence by hand.

**Nothing in it stops to be countersigned. Running it is the decision to ship**,
so the decision belongs to the user and reaches this role as an instruction to
ship a named channel, never as a judgement to make here.

`release.sh` is still the way to build and prepare without publishing anything -
without `LUKOTTA_PUBLISH=1` everything is built and nothing goes out, which is
how to see what a release would say.

## Things this project has already been caught by

- **The build number is the commit count, and it must exceed the published
  one.** Sparkle offers an update only on a higher build number. A hotfix cut
  from a shorter branch, a squash merge or a rewrite produces a number already
  released, and Sparkle then answers "up to date" to everybody for a release
  that fixes something. The check reads the published feed rather than trusting
  the tag; do not work around it.
- **What the feed reports, not the last tag.** Versions get tagged here without
  ever being released; three have been. The notes describe everything the people
  receiving the update have not seen.
- **Release notes are tied to the words they shipped with.** `releases/APPROVED`
  must name the version beside the hash of `releases/<version>.md` as it stands.
  It stops a release going out under notes edited after they were written.
- **Do not edit `ship.sh` while it is running.** bash reads a script by byte
  offset, so an edit under a running instance resumes it mid-line. It happened
  twice in one hour, both times after the GitHub release was published and
  before the appcast was committed - a version that existed and nobody was
  offered. The script now runs from a copy of itself for that reason.
- **A beta is not gated; a release is.** Publish betas freely. `ship.sh release`
  runs `beta-proven.sh`, which refuses unless `prove-beta.sh` proved a beta of
  that version, its log is the one recorded, every step passed, no speed fell
  more than a quarter, and nothing outside `releases/` changed since.
  `prove-beta.sh` is the only writer of `releases/proofs/` and
  `releases/BETA-PROVEN`; it commits and pushes them itself.
- **Branding is opt-in.** Builds are unbranded by default because the name and
  logo are trademarks the GPL does not cover; the release path uses
  `LUKOTTA_BRANDING=official`, and nothing else should.
