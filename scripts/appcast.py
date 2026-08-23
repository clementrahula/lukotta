#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Add a release to the Sparkle appcast.

Kept apart from release.sh because this is the part that must not go wrong
quietly: an appcast that parses but describes the wrong build is indisitinguishable
from a working one until an update fails on someone else's machine.
"""
import argparse, os, sys
from xml.etree import ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lukotta</title>
    <link>https://lukotta-updates.rahula.dev/appcast.xml</link>
    <description>Updates for Lukotta.</description>
    <language>en</language>
  </channel>
</rss>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True)
    ap.add_argument("--version", required=True, help="marketing version, e.g. 1.7.0")
    ap.add_argument("--build", required=True, help="CFBundleVersion, the number Sparkle compares")
    ap.add_argument("--url", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--min-system", default="15.0")
    ap.add_argument("--pubdate", required=True, help="RFC 822")
    ap.add_argument("--notes-link", default="", help="URL of the release notes for this version")
    ap.add_argument(
        "--delta",
        action="append",
        default=[],
        metavar="FROM_BUILD:URL:LENGTH:SIGNATURE",
        help="an update from one earlier build, which Sparkle prefers to the whole archive",
    )
    args = ap.parse_args()

    if not os.path.exists(args.appcast):
        with open(args.appcast, "w") as f:
            f.write(EMPTY)

    tree = ET.parse(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit("error: appcast has no <channel>")

    # Replacing rather than appending: re-running a release must not leave two
    # entries claiming the same build with different signatures.
    for item in channel.findall("item"):
        if item.findtext(f"{{{SPARKLE}}}version") == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = args.pubdate
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = args.min_system
    # Linked rather than embedded: release notes are HTML, and HTML inside XML
    # has to be escaped or wrapped in CDATA, neither of which ElementTree does
    # well. A link is also what lets notes be corrected without reissuing a
    # signed build.
    if args.notes_link:
        ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = args.notes_link
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", args.length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE}}}edSignature", args.signature)

    # Newest first, which is how a person reads it; Sparkle does not care.
    # What somebody on an earlier build downloads instead of the whole thing.
    # Sparkle takes the delta matching their build when there is one and falls
    # back to the enclosure above when there is not, so a missing delta costs
    # bandwidth rather than correctness.
    #
    # These enclosures carry no version of their own, and do not need one:
    # Sparkle builds each delta as a copy of this item with the delta enclosure
    # substituted (SUAppcastItem.m), so it inherits the <sparkle:version> and
    # <sparkle:shortVersionString> written above. Checked against Sparkle 2.9.6,
    # the version in Package.resolved.
    if args.delta:
        deltas = ET.SubElement(item, f"{{{SPARKLE}}}deltas")
        for spec in args.delta:
            # A URL has colons in it, so the fields around it are taken from
            # each end rather than by splitting the lot.
            from_build, rest = spec.split(":", 1)
            url, length, signature = rest.rsplit(":", 2)
            patch = ET.SubElement(deltas, "enclosure")
            patch.set("url", url)
            patch.set("length", length)
            patch.set("type", "application/octet-stream")
            patch.set(f"{{{SPARKLE}}}deltaFrom", from_build)
            patch.set(f"{{{SPARKLE}}}edSignature", signature)

    existing = channel.findall("item")
    channel.insert(list(channel).index(existing[0]) if existing else len(list(channel)), item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {args.appcast} now describes build {args.build} ({args.version})")


if __name__ == "__main__":
    main()
