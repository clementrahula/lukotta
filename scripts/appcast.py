#!/usr/bin/env python3
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
    ap.add_argument("--notes", default="")
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
    if args.notes:
        ET.SubElement(item, "description").text = args.notes
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", args.length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE}}}edSignature", args.signature)

    # Newest first, which is how a person reads it; Sparkle does not care.
    existing = channel.findall("item")
    channel.insert(list(channel).index(existing[0]) if existing else len(list(channel)), item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {args.appcast} now describes build {args.build} ({args.version})")


if __name__ == "__main__":
    main()
