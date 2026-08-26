#!/usr/bin/env python3
"""Generate the Punte launcher-icon source images.

Punte = "bridge" (Romanian). The mark is a bold suspension bridge — deck +
two towers + a draped main cable with hangers — in black on the Nano-blue ->
teal diagonal gradient (the same brand DNA as the old Ӿ mark it replaces).

Writes the three sources consumed by flutter_launcher_icons:
  assets/icon/icon.png        full-bleed gradient circle + glyph (iOS/legacy)
  assets/icon/foreground.png  glyph on transparent  (adaptive foreground)
  assets/icon/background.png  full-square gradient   (adaptive background)

Run from the app/ directory, then regenerate the mipmaps:
    python3 tool/gen_launcher_icon.py
    dart run flutter_launcher_icons
The adaptive foreground is already sized for the mask safe zone, so the
generated mipmap-anydpi-v26/ic_launcher.xml is edited to drop the default
16% <foreground> inset (which would otherwise shrink the glyph twice).
"""
import os
from PIL import Image, ImageDraw

SS = 4                       # supersample factor
N = 1024                     # final source size
W = N * SS
BLUE = (62, 158, 249)        # top-left  #3E9EF9
TEAL = (76, 204, 172)        # bottom-right #4CCCAC
ICON_DIR = os.path.join(os.path.dirname(__file__), os.pardir, "assets", "icon")


def gradient_square():
    """Diagonal linear gradient BLUE(TL) -> TEAL(BR) along the (x+y) axis."""
    img = Image.new("RGB", (W, W))
    px = img.load()
    maxd = 2 * (W - 1)
    for y in range(W):
        for x in range(W):
            t = (x + y) / maxd
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(BLUE, TEAL))
    return img


def _rrect(d, x0, y0, x1, y1, r, fill):
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill)


def _thick_polyline(d, pts, width, color):
    """Polyline with round joints and round caps."""
    d.line(pts, fill=color, width=int(round(width)), joint="curve")
    r = width / 2
    for (x, y) in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw_glyph(scale=1.0, color=(0, 0, 0, 255)):
    """Suspension-bridge mark, centered, on a transparent WxW layer."""
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = cy = W / 2
    s = SS * scale

    tower_w, deck_w, cable_w, susp_w = 50 * s, 54 * s, 30 * s, 13 * s
    deck_y = cy + 96 * s                 # roadway centre-line
    deck_hw = 342 * s                    # roadway extends past the towers
    tower_top, tower_base = cy - 178 * s, cy + 140 * s
    tx = 156 * s
    lt, rt = cx - tx, cx + tx            # tower x positions

    def cable_y(x):                      # parabola dipping between towers
        u = (x - cx) / tx                # -1..1 at the towers
        sag = (deck_y - 16 * s) - tower_top
        return tower_top + sag * (1 - u * u)

    # main cable: draped centre span between the two towers
    span = [(lt + (rt - lt) * i / 40.0, cable_y(lt + (rt - lt) * i / 40.0))
            for i in range(41)]
    _thick_polyline(d, span, cable_w, color)

    # vertical hangers (centre span)
    for frac in (0.2, 0.4, 0.6, 0.8):
        x = lt + (rt - lt) * frac
        d.line([(x, cable_y(x)), (x, deck_y)], fill=color, width=int(susp_w))

    # two towers
    for txc in (lt, rt):
        _rrect(d, txc - tower_w / 2, tower_top, txc + tower_w / 2,
               tower_base, tower_w / 2, color)

    # deck (roadway)
    _rrect(d, cx - deck_hw, deck_y - deck_w / 2, cx + deck_hw,
           deck_y + deck_w / 2, deck_w / 2, color)
    return layer


def build():
    grad = gradient_square()
    out = lambda f: os.path.join(ICON_DIR, f)

    grad.resize((N, N), Image.LANCZOS).save(out("background.png"))

    # adaptive foreground — scaled to sit inside the circular-mask safe zone
    draw_glyph(scale=0.86).resize((N, N), Image.LANCZOS).save(out("foreground.png"))

    # full-bleed circle for iOS / legacy launchers
    circle = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, W - 1, W - 1], fill=255)
    circle.paste(grad, (0, 0), mask)
    circle.alpha_composite(draw_glyph(scale=1.12))
    circle.resize((N, N), Image.LANCZOS).save(out("icon.png"))


if __name__ == "__main__":
    build()
    print("wrote icon.png, foreground.png, background.png ->", os.path.normpath(ICON_DIR))
