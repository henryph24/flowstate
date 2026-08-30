#!/usr/bin/env python3
"""Build Resources/murmur.icns from full-bleed square artwork.

Applies Apple's macOS icon geometry: 824px rounded-square (r ≈ 22.5%)
centered on a transparent 1024px canvas, then emits every iconset size.

Usage: uv run --with pillow python scripts/make_icns.py <artwork.png> <out.icns>
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

CANVAS = 1024
SQUIRCLE = 824
RADIUS = 185  # ≈ 22.5% of 824, Apple's visual corner radius
SUPERSAMPLE = 4

artwork_path, icns_path = Path(sys.argv[1]), Path(sys.argv[2])

art = Image.open(artwork_path).convert("RGBA").resize((SQUIRCLE, SQUIRCLE), Image.LANCZOS)

big = SQUIRCLE * SUPERSAMPLE
mask = Image.new("L", (big, big), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (0, 0, big - 1, big - 1), radius=RADIUS * SUPERSAMPLE, fill=255)
mask = mask.resize((SQUIRCLE, SQUIRCLE), Image.LANCZOS)

master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
offset = (CANVAS - SQUIRCLE) // 2
master.paste(art, (offset, offset), mask)

SIZES = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
         ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
         ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
         ("icon_512x512@2x", 1024)]

with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / "murmur.iconset"
    iconset.mkdir()
    for name, size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(iconset / f"{name}.png")
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
                   check=True)
print(f"wrote {icns_path}")
