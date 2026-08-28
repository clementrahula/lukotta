#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Draw a channel's app icon by banding the one it is a variant of.

    scripts/make-channel-icon.py beta    the mark, banded BETA
    scripts/make-channel-icon.py v2      the placeholder, banded V2

Four of these can sit in the same Dock and the same Applications folder with
names that differ by a word. Telling them apart by reading is telling them apart
too late: each writes to its own drives with its own helper, and the moment
somebody reports a fault against the wrong one, an evening goes into finding out
which app they were actually running.

So a channel keeps the picture of whatever it is a variant of and wears a band
across the foot of it. Nothing else changes: same silhouette at 16 pt, where a
band is a darker edge and the picture is still the picture.

Both band the mark. A beta is the released app a week early and v2 is the same
application rewritten, so both are Lukotta and both say which one they are on
the band. dev keeps the unbranded placeholder, which leaves four pictures for
four channels.
"""

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = HERE / "sources/Lukotta/Assets.xcassets"

# What each channel is a variant of, what it is called, and the word on the
# band. build-app.sh names the same sets in its ICON_SET.
CHANNELS = {
    "beta": ("AppIcon", "AppIconBeta", "BETA"),
    "v2": ("AppIcon", "AppIconV2", "V2"),
}

# The band: the app's own orange, the colour the interface already uses when it
# wants attention without alarm. One colour for every channel -- the band says
# "not the release", and which channel it is, is what the word is for.
BAND = (214, 116, 32, 255)
TEXT = (255, 255, 255, 255)


def banded(image: Image.Image, word: str) -> Image.Image:
    out = image.convert("RGBA")
    width, height = out.size
    band_height = max(2, round(height * 0.26))
    top = height - band_height

    layer = Image.new("RGBA", out.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rectangle([0, top, width, height], fill=BAND)
    # Kept inside the icon's own outline. A rectangle over a rounded corner
    # squares it off, and an icon with two square corners looks broken rather
    # than marked.
    layer.putalpha(
        Image.composite(
            layer.getchannel("A"), Image.new("L", out.size, 0), out.getchannel("A")))

    # Below about 32 px the word cannot be read at all, and a smear of white
    # reads as damage. The band alone carries it at those sizes.
    if height >= 64:
        size = max(8, round(band_height * 0.62))
        font = None
        for candidate in [
            "/System/Library/Fonts/SFNSDisplay.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/Library/Fonts/Arial Bold.ttf",
        ]:
            if pathlib.Path(candidate).exists():
                try:
                    font = ImageFont.truetype(candidate, size)
                    break
                except OSError:
                    continue
        if font is None:
            font = ImageFont.load_default()
        left, upper, right, lower = draw.textbbox((0, 0), word, font=font)
        draw.text(
            ((width - (right - left)) / 2 - left,
             top + (band_height - (lower - upper)) / 2 - upper),
            word, font=font, fill=TEXT)

    return Image.alpha_composite(out, layer)


def main() -> int:
    channel = sys.argv[1] if len(sys.argv) > 1 else ""
    if channel not in CHANNELS:
        print(f"usage: {sys.argv[0]} {'|'.join(CHANNELS)}", file=sys.stderr)
        return 1
    from_set, to_set, word = CHANNELS[channel]
    source = CATALOGUE / f"{from_set}.appiconset"
    target = CATALOGUE / f"{to_set}.appiconset"
    if not source.is_dir():
        print(f"error: no icon at {source}", file=sys.stderr)
        return 1
    target.mkdir(parents=True, exist_ok=True)
    written = 0
    for path in sorted(source.iterdir()):
        if path.suffix == ".png":
            banded(Image.open(path), word).save(target / path.name)
            written += 1
        elif path.name == "Contents.json":
            (target / path.name).write_text(path.read_text())
    print(f"  {written} images written to {target.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
