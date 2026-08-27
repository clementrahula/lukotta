#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Draw the window around the two pictures the README shows.

    ./scripts/readme-shots.py [screenshot-directory]

The site puts its captures inside a macOS window it draws in CSS: a title bar
with the three buttons, a hairline border, a rounded corner. A README cannot do
that. GitHub strips style attributes, so there is no border, no radius and no
way to space two pictures apart -- which is why the two in the README sat
square and touching while the same captures looked like windows on the site.

So the window is drawn into the file instead, at the measurements the site
uses, and a transparent margin is left around it. That margin is what holds the
two apart, side by side on a wide screen and one above the other on a narrow
one, without a table or a spacer image.

The captures themselves stay as they are. The site draws its own frame around
them and would show this one inside it.
"""
import pathlib
import struct
import sys

from PIL import Image, ImageDraw

# What .shot and .shot-bar say, in points, doubled because the captures are
# drawn at twice the density.
SCALE = 2
BAR = 28 * SCALE       # title bar height
BUTTON = 12 * SCALE    # each of the three
BETWEEN = 8 * SCALE    # space between them
LEADING = 20 * SCALE   # from the leading edge to the first
RADIUS = 10 * SCALE    # macOS's corner
BORDER = 1 * SCALE     # the hairline round the window and under the bar
MARGIN = 14 * SCALE    # transparent, and the only thing holding the two apart

SUPERSAMPLE = 4        # a rounded corner drawn at size comes out stepped

# --titlebar and --titlebar-edge, both appearances.
PAPER = {
    "light": {"bar": (236, 236, 236), "edge": (214, 211, 205)},
    "dark": {"bar": (44, 46, 51), "edge": (58, 61, 68)},
}
BUTTONS = ((255, 95, 87), (254, 188, 46), (40, 200, 64))


def density(raw):
    """The pHYs the app wrote, so the copy is still a two-times picture."""
    at = 8
    while at < len(raw):
        length, kind = struct.unpack_from(">I4s", raw, at)
        if kind == b"pHYs":
            x, y, unit = struct.unpack_from(">IIB", raw, at + 8)
            return (round(x * 0.0254), round(y * 0.0254)) if unit == 1 else None
        at += 12 + length
    return None


def rounded_mask(size, radius):
    """A rounded rectangle with a clean edge, drawn large and shrunk."""
    width, height = size
    big = Image.new("L", (width * SUPERSAMPLE, height * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, width * SUPERSAMPLE - 1, height * SUPERSAMPLE - 1),
        radius=radius * SUPERSAMPLE, fill=255)
    return big.resize((width, height), Image.LANCZOS)


def darker(colour, by=0.14):
    """The inset shadow the site puts round each button, near enough."""
    return tuple(round(channel * (1 - by)) for channel in colour)


def frame(source, shade):
    raw = source.read_bytes()
    capture = Image.open(source).convert("RGB")
    width, height = capture.size

    paper = PAPER[shade]
    window = (width + BORDER * 2, BAR + BORDER * 3 + height)
    canvas = Image.new("RGBA", window, (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # The hairline, then everything inside it.
    draw.rounded_rectangle((0, 0, window[0] - 1, window[1] - 1),
                           radius=RADIUS, fill=paper["edge"])
    draw.rounded_rectangle(
        (BORDER, BORDER, window[0] - 1 - BORDER, window[1] - 1 - BORDER),
        radius=RADIUS - BORDER, fill=paper["bar"])

    # The capture sits under the bar and the line beneath it.
    canvas.paste(capture, (BORDER, BORDER + BAR + BORDER))

    draw.rectangle((BORDER, BORDER + BAR,
                    window[0] - 1 - BORDER, BORDER + BAR + BORDER - 1),
                   fill=paper["edge"])

    # macOS does not mirror these in right-to-left locales, and neither does
    # the site, so they stay on the left in every language.
    middle = BORDER + BAR / 2
    for index, colour in enumerate(BUTTONS):
        left = BORDER + LEADING + index * (BUTTON + BETWEEN)
        box = (left, middle - BUTTON / 2, left + BUTTON - 1, middle + BUTTON / 2 - 1)
        draw.ellipse(box, fill=colour, outline=darker(colour), width=1)

    # Which also clips the capture's square bottom corners.
    canvas.putalpha(rounded_mask(window, RADIUS))

    spaced = Image.new(
        "RGBA", (window[0] + MARGIN * 2, window[1] + MARGIN * 2), (0, 0, 0, 0))
    spaced.paste(canvas, (MARGIN, MARGIN), canvas)
    return spaced, density(raw)


def main():
    where = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "assets/screenshots")
    for shade in ("light", "dark"):
        source = where / f"en-{shade}.png"
        if not source.exists():
            sys.exit(f"error: no capture at {source}")
        picture, dots = frame(source, shade)
        out = where / f"en-{shade}-readme.png"
        picture.save(out, **({"dpi": dots} if dots else {}))
        print(f"  {out.name}, {picture.size[0]}x{picture.size[1]}")


if __name__ == "__main__":
    main()
