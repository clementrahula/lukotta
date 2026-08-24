#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Draw the beta app icon from the released one.

The two apps sit in the same Dock and the same Applications folder, with the
same name apart from one word. Telling them apart by reading is telling them
apart too late: the beta writes to its own drives with its own helper, and the
moment somebody reports a fault against the wrong one, an evening goes into
finding out which app they were actually running.

So the beta keeps the mark -- it is the same app -- and wears a band across the
foot of it. Nothing else changes: same silhouette at 16 pt, where a band is a
darker edge and the mark is still the mark.
"""

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent.parent
SOURCE = HERE / "sources/Lukotta/Assets.xcassets/AppIcon.appiconset"
TARGET = HERE / "sources/Lukotta/Assets.xcassets/AppIconBeta.appiconset"

# The band: the app's own orange, the colour the interface already uses when it
# wants attention without alarm.
BAND = (214, 116, 32, 255)
TEXT = (255, 255, 255, 255)


def banded(image: Image.Image) -> Image.Image:
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
        word = "BETA"
        if font is None:
            font = ImageFont.load_default()
        left, upper, right, lower = draw.textbbox((0, 0), word, font=font)
        draw.text(
            ((width - (right - left)) / 2 - left,
             top + (band_height - (lower - upper)) / 2 - upper),
            word, font=font, fill=TEXT)

    return Image.alpha_composite(out, layer)


def main() -> int:
    if not SOURCE.is_dir():
        print(f"error: no icon at {SOURCE}", file=sys.stderr)
        return 1
    TARGET.mkdir(parents=True, exist_ok=True)
    written = 0
    for path in sorted(SOURCE.iterdir()):
        if path.suffix == ".png":
            banded(Image.open(path)).save(TARGET / path.name)
            written += 1
        elif path.name == "Contents.json":
            (TARGET / path.name).write_text(path.read_text())
    print(f"  {written} images written to {TARGET.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
