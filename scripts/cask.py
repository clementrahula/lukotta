#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Write the Homebrew cask for one channel.

    ./scripts/cask.py release 1.19.0 <sha256> > Casks/lukotta.rb
    ./scripts/cask.py beta    1.19.0 <sha256> > Casks/lukotta@beta.rb

Called by scripts/release.sh with the checksum of the disk image it has just
uploaded, so the cask can never describe a release that was not made. Written
here rather than in the tap because the two casks differ in eight small ways
and agree in twenty: kept as two files, an edit to one of them is an edit
somebody forgot to make twice.

Homebrew's own cask repository will not take this app -- it refuses on
notability, not on quality -- so the tap is the distribution. It is the same
file either way, and transfers unchanged if that ever stops being true.
"""
import sys

REPO = "clementrahula/lukotta"

CHANNELS = {
    "release": {
        "token": "lukotta",
        "app": "Lukotta.app",
        "identifier": "com.lukotta",
        "image": "Lukotta.dmg",
        "tag": "v#{version}",
        "name": "Lukotta",
        # The newest release that is not marked pre-release, which is exactly
        # what this channel publishes.
        "livecheck": "github_latest",
    },
    "beta": {
        "token": "lukotta@beta",
        "app": "Lukotta Beta.app",
        "identifier": "com.lukotta.beta",
        "image": "Lukotta-Beta.dmg",
        "tag": "v#{version}-beta",
        "name": "Lukotta Beta",
        # Every release, including the ones marked pre-release. The other
        # strategy passes over this channel entirely.
        "livecheck": "github_releases",
    },
}


def cask(channel: str, version: str, checksum: str) -> str:
    c = CHANNELS[channel]
    identifier = c["identifier"]
    return f'''cask "{c["token"]}" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/{REPO}/releases/download/{c["tag"]}/{c["image"]}",
      verified: "github.com/{REPO}/"
  name "{c["name"]}"
  desc "Opens BitLocker, LUKS and NTFS drives and disk images in Finder"
  homepage "https://lukotta.com/"

  livecheck do
    url :url
    strategy :{c["livecheck"]}
  end

  # The app carries Sparkle and updates itself. Without this, Homebrew treats a
  # version it did not install as damage and reinstalls over it.
  auto_updates true
  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "{c["app"]}"

  # Stopping the daemon is all an ordinary uninstall does here.
  #
  # The files it leaves in /Library belong to root, and Homebrew removes those
  # by shelling out to `sudo rm` -- which it does whether or not they are
  # there. Naming them here therefore asked for an administrator password on
  # every upgrade, on every Mac, including the ones where the daemon was never
  # set up and there was nothing to delete. `brew upgrade` cannot answer a
  # password prompt, so it did not upgrade; it failed.
  #
  # They belong under zap, which is the stanza for what only somebody asking to
  # be rid of the app entirely should pay for.
  uninstall launchctl: "{identifier}.helper",
            quit:      "{identifier}"

  # Everything the app keeps. The two under /Library need root and are why
  # `brew uninstall --zap` asks for a password; the rest are this user's own.
  # Saved passphrases are Keychain items rather than files, so they outlive
  # this -- the app's own uninstaller is what clears those.
  zap launchctl: "{identifier}.helper",
      delete:    [
        "/Library/LaunchDaemons/{identifier}.helper.plist",
        "/Library/PrivilegedHelperTools/{identifier}.helper",
      ],
      trash:     [
        "~/Library/Application Support/{identifier}",
        "~/Library/Caches/{identifier}",
        "~/Library/HTTPStorages/{identifier}",
        "~/Library/Preferences/{identifier}.plist",
        "~/Library/Saved Application State/{identifier}.savedState",
      ]
end
'''


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in CHANNELS:
        print(f"usage: {sys.argv[0]} [release|beta] <version> <sha256>", file=sys.stderr)
        return 2
    _, channel, version, checksum = sys.argv
    if len(checksum) != 64 or any(c not in "0123456789abcdef" for c in checksum):
        print("error: that is not a sha256", file=sys.stderr)
        return 1
    sys.stdout.write(cask(channel, version, checksum))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
