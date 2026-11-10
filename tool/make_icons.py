"""Regenerates every CamStation icon from the logo geometry (design "B –
viewfinder", drawn in a 280-unit box). Run from the repo root:

    python3 tool/make_icons.py

Writes assets/logo/*, Android launcher icons (legacy + adaptive), the
Windows .ico and the Linux icon. Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw

BG = "#111827"      # near-black slate
FG = "#FFFFFF"
ACCENT = "#22C55E"  # "online" green
BOX = 280.0
RADIUS = 64.0
BRACKETS = [  # polylines, stroke 16, round caps/joins
    [(55, 105), (55, 55), (105, 55)],
    [(175, 55), (225, 55), (225, 105)],
    [(55, 175), (55, 225), (105, 225)],
    [(175, 225), (225, 225), (225, 175)],
]
BRACKET_W, RING_R, RING_W, DOT_R = 16, 42, 14, 14

ROOT = Path(__file__).resolve().parent.parent


def svg() -> str:
    paths = " ".join(
        "M{} {} L{} {} L{} {}".format(*[c for p in b for c in p]) for b in BRACKETS
    )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 280 280">
  <title>CamStation</title>
  <rect width="280" height="280" rx="{RADIUS:g}" fill="{BG}"/>
  <path d="{paths}" fill="none" stroke="{FG}" stroke-width="{BRACKET_W}" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="140" cy="140" r="{RING_R}" fill="none" stroke="{FG}" stroke-width="{RING_W}"/>
  <circle cx="140" cy="140" r="{DOT_R}" fill="{ACCENT}"/>
</svg>
"""


def _line(d: ImageDraw.ImageDraw, pts, w, k, color):
    pts = [(x * k, y * k) for x, y in pts]
    d.line(pts, fill=color, width=round(w * k), joint="curve")
    r = w * k / 2
    for x, y in (pts[0], pts[-1]):  # round caps
        d.ellipse((x - r, y - r, x + r, y + r), fill=color)


def glyph(d: ImageDraw.ImageDraw, k: float, ox: float = 0, oy: float = 0):
    """Brackets + lens, scaled by k, offset by (ox, oy) pixels."""
    for b in BRACKETS:
        _line(d, [(x + ox / k, y + oy / k) for x, y in b], BRACKET_W, k, FG)
    cx, cy = 140 * k + ox, 140 * k + oy
    ro, ri = (RING_R + RING_W / 2) * k, (RING_R - RING_W / 2) * k
    d.ellipse((cx - ro, cy - ro, cx + ro, cy + ro), fill=FG)
    d.ellipse((cx - ri, cy - ri, cx + ri, cy + ri), fill=(0, 0, 0, 0))
    r = DOT_R * k
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ACCENT)


def icon(size: int, rounded=True, ss=4) -> Image.Image:
    """Full icon (rounded square, transparent corners), supersampled."""
    n = size * ss
    k = n / BOX
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if rounded:
        d.rounded_rectangle((0, 0, n - 1, n - 1), radius=RADIUS * k, fill=BG)
    else:
        d.rectangle((0, 0, n, n), fill=BG)
    # The ring's hole must show the background, not transparency.
    glyph(d, k)
    cx = cy = 140 * k
    ri = (RING_R - RING_W / 2) * k
    d.ellipse((cx - ri, cy - ri, cx + ri, cy + ri), fill=BG)
    r = DOT_R * k
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ACCENT)
    return im.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size: int, ss=4) -> Image.Image:
    """Android adaptive foreground (108dp canvas): the glyph's bracket box
    (186 of 280 units incl. stroke) fits the square inscribed in the 66dp
    safe circle (≈46dp), so no launcher mask clips the corners."""
    n = size * ss
    box_px = n * 46 / 108
    k = box_px / 186
    off = (n - BOX * k) / 2
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    glyph(d, k, off, off)
    return im.resize((size, size), Image.LANCZOS)


def main():
    logo = ROOT / "assets/logo"
    logo.mkdir(parents=True, exist_ok=True)
    (logo / "camstation.svg").write_text(svg())
    icon(1024).save(logo / "camstation-1024.png")
    icon(256).save(logo / "camstation-256.png")

    res = ROOT / "android/app/src/main/res"
    for folder, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        icon(px).save(res / f"mipmap-{folder}/ic_launcher.png")
        fg = int(px * 108 / 48)
        adaptive_foreground(fg).save(res / f"mipmap-{folder}/ic_launcher_foreground.png")
    any_dpi = res / "mipmap-anydpi-v26"
    any_dpi.mkdir(exist_ok=True)
    (any_dpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n"
    )
    values = res / "values"
    values.mkdir(exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{BG}</color>\n</resources>\n'
    )

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    icon(256).save(
        ROOT / "windows/runner/resources/app_icon.ico",
        sizes=[(s, s) for s in ico_sizes],
    )
    icon(256).save(ROOT / "linux/camstation.png")
    print("icons written")


if __name__ == "__main__":
    main()
