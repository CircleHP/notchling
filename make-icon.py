#!/usr/bin/env python3
"""
Generate Notchling.icns from the same pixel art the widget draws, so the two cannot drift.

    python3 make-icon.py            -> Resources/Notchling.icns

Requires Pillow and macOS `iconutil`. The generated .icns is committed, so this only needs running
after changing the art.
"""

import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

# The standing critter, character-for-character identical to MascotArt.standing in
# Sources/Notchling/UI/Mascot/MascotArt.swift. `#` is a lit pixel; the eyes are holes, so the
# backdrop shows through them.
CRITTER = [
    "...##...##...",
    "..#########..",
    ".###########.",
    "###..###..###",
    "###..###..###",
    "#############",
    "#############",
    ".###.....###.",
    "..#########..",
    "..##.....##..",
]

# Theme.claude.
CLAY = (217, 119, 87, 255)
BACKDROP_TOP = (38, 36, 34, 255)
BACKDROP_BOTTOM = (22, 21, 20, 255)

# The only logical sizes `iconutil` accepts. 64 is deliberately absent: `icon_64x64.png` is not a
# valid iconset member name, and including it can make macOS reject the whole set — which shows up
# as a generic placeholder icon on notifications rather than as an error.
LOGICAL_SIZES = [16, 32, 128, 256, 512]


def lit_pixels(rows):
    """ASCII rows -> (width, height, set of lit (x, y))."""
    width = max(len(r) for r in rows)
    lit = {(x, y) for y, row in enumerate(rows) for x, c in enumerate(row) if c == "#"}
    return width, len(rows), lit


def render(size):
    """One square icon at `size`px."""
    # Supersample so the rounded corners and pixel edges stay clean when downscaled.
    scale = 4 if size <= 256 else 2
    s = size * scale
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Gradient backdrop, masked to a rounded square.
    gradient = Image.new("RGBA", (1, s))
    for y in range(s):
        t = y / max(1, s - 1)
        gradient.putpixel(
            (0, y),
            tuple(
                round(a + (b - a) * t)
                for a, b in zip(BACKDROP_TOP, BACKDROP_BOTTOM)
            ),
        )
    backdrop = gradient.resize((s, s))

    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        # macOS app icons sit inside their canvas rather than bleeding to the edge.
        [s * 0.055, s * 0.055, s * 0.945, s * 0.945],
        radius=s * 0.205,
        fill=255,
    )
    image.paste(backdrop, (0, 0), mask)

    # The critter, centred, on square pixels — the same rule as the widget.
    grid_w, grid_h, lit = lit_pixels(CRITTER)
    unit = (s * 0.62) / max(grid_w, grid_h)
    origin_x = (s - unit * grid_w) / 2
    origin_y = (s - unit * grid_h) / 2

    draw = ImageDraw.Draw(image)
    for x, y in lit:
        draw.rectangle(
            [
                origin_x + x * unit,
                origin_y + y * unit,
                origin_x + (x + 1) * unit,
                origin_y + (y + 1) * unit,
            ],
            fill=CLAY,
        )

    return image.resize((size, size), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    output = os.path.join(root, "Resources", "Notchling.icns")
    os.makedirs(os.path.dirname(output), exist_ok=True)

    if not shutil.which("iconutil"):
        sys.exit("iconutil not found (macOS only)")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "Notchling.iconset")
        os.makedirs(iconset)

        # Each logical size at 1x and 2x: icon_16x16.png, icon_16x16@2x.png, …
        for size in LOGICAL_SIZES:
            render(size).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            render(size * 2).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))

        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", output], check=True)

    print(f"wrote {output} ({os.path.getsize(output)} bytes)")


if __name__ == "__main__":
    main()
