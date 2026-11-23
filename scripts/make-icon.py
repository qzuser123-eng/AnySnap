#!/usr/bin/env python3
"""Draws the AnySnap app icon and writes Resources/AppIcon.icns (+ a 1024px PNG preview).

Design: macOS-style rounded square, blue→indigo gradient, a white app window
(title bar with three dots, a few text lines) framed by camera-viewfinder corners.
Run:  python3 scripts/make-icon.py
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 4                      # supersampling factor
N = 1024 * S               # working canvas
root = Path(__file__).resolve().parent.parent
out_dir = root / "Resources"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def draw_icon() -> Image.Image:
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Apple icon grid: 824px body on a 1024 canvas, corner radius ~185
    m = 100 * S
    body = (m, m, N - m, N - m)
    radius = 185 * S

    # soft drop shadow
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + 14 * S, body[2], body[3] + 14 * S), radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18 * S))
    img.alpha_composite(shadow)

    # gradient body
    top, bottom = (64, 140, 255), (88, 64, 214)
    grad = Image.new("RGBA", (N, N))
    gd = ImageDraw.Draw(grad)
    for y in range(N):
        gd.line([(0, y), (N, y)], fill=lerp(top, bottom, y / N) + (255,))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # subtle top highlight
    fade = Image.new("L", (N, N), 0)
    fd = ImageDraw.Draw(fade)
    span = 520 * S
    for y in range(body[1], body[1] + span):
        fd.line([(0, y), (N, y)], fill=int(46 * (1 - (y - body[1]) / span)))
    fade = Image.composite(fade, Image.new("L", (N, N), 0), mask)
    white_layer = Image.new("RGBA", (N, N), (255, 255, 255, 255))
    white_layer.putalpha(fade)
    img.alpha_composite(white_layer)

    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)

    # viewfinder corners
    c0, c1 = 236 * S, (1024 - 236) * S
    arm, w = 118 * S, 30 * S
    r = w // 2
    for (x, y, dx, dy) in [(c0, c0, 1, 1), (c1, c0, -1, 1), (c0, c1, 1, -1), (c1, c1, -1, -1)]:
        d.rounded_rectangle((min(x, x + dx * arm), min(y, y + dy * w), max(x, x + dx * arm), max(y, y + dy * w)),
                            r, fill=white)
        d.rounded_rectangle((min(x, x + dx * w), min(y, y + dy * arm), max(x, x + dx * w), max(y, y + dy * arm)),
                            r, fill=white)

    # app window
    wx0, wy0, wx1, wy1 = 330 * S, 352 * S, (1024 - 330) * S, (1024 - 340) * S
    d.rounded_rectangle((wx0, wy0, wx1, wy1), 44 * S, fill=white)
    bar = wy0 + 78 * S
    d.rectangle((wx0, bar - 2 * S, wx1, bar + 2 * S), fill=(214, 221, 240, 255))
    for i, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy, rr = wx0 + (58 + i * 46) * S, wy0 + 39 * S, 15 * S
        d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=col + (255,))
    # text lines
    lx0 = wx0 + 52 * S
    for i, frac in enumerate([0.78, 0.62, 0.70]):
        ly = bar + (54 + i * 58) * S
        d.rounded_rectangle((lx0, ly, lx0 + int((wx1 - wx0 - 104 * S) * frac), ly + 24 * S), 12 * S,
                            fill=(120, 132, 230, 255) if i == 0 else (196, 203, 232, 255))

    return img.resize((1024, 1024), Image.LANCZOS)


def build_icns(master: Image.Image) -> bytes:
    # PNG-backed icns entries
    entries = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
               ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    chunks = b""
    for code, px in entries:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, "PNG")
        data = buf.getvalue()
        chunks += code.encode() + struct.pack(">I", len(data) + 8) + data
    return b"icns" + struct.pack(">I", len(chunks) + 8) + chunks


if __name__ == "__main__":
    out_dir.mkdir(exist_ok=True)
    icon = draw_icon()
    icon.save(out_dir / "AppIcon-1024.png")
    (out_dir / "AppIcon.icns").write_bytes(build_icns(icon))
    print("wrote", out_dir / "AppIcon.icns")
    sys.exit(0)
