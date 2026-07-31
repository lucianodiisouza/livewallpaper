#!/usr/bin/env python3
"""Generate abstract macOS icon concepts for 'Primo Engine'."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4            # supersample factor
N = S * SS
OUT = "/private/tmp/claude-501/-Users-lucianodiisouza-livewallpaper/5f83781e-d083-43e0-a9d2-6135412e3c57/scratchpad"


def squircle_mask(n, radius_frac=0.225):
    """Apple-style continuous rounded-rect (approximated with a big corner radius)."""
    m = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(m)
    r = int(n * radius_frac)
    d.rounded_rectangle([0, 0, n - 1, n - 1], radius=r, fill=255)
    return m


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgrad(n, top, bottom):
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        c = lerp(top, bottom, y / (n - 1))
        for x in range(n):
            px[x, y] = c
    return img


def diag_grad(n, c1, c2):
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            t = (x + y) / (2 * (n - 1))
            px[x, y] = lerp(c1, c2, t)
    return img


def radial_glow(n, center, color, radius, strength=1.0):
    """Return an RGBA glow layer."""
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = layer.load()
    cx, cy = center
    r2 = radius * radius
    for y in range(n):
        for x in range(n):
            dx, dy = x - cx, y - cy
            d2 = dx * dx + dy * dy
            if d2 < r2:
                t = 1 - math.sqrt(d2) / radius
                a = int(255 * (t ** 2) * strength)
                px[x, y] = (color[0], color[1], color[2], a)
    return layer


# ---------------------------------------------------------------- concept 1
def concept_prism():
    """A beam of light striking a prism and fanning into a spectrum."""
    img = vgrad(N, (18, 20, 32), (8, 8, 16)).convert("RGBA")
    draw = ImageDraw.Draw(img, "RGBA")

    cx, cy = N * 0.52, N * 0.5
    size = N * 0.26
    # prism triangle
    tri = [(cx, cy - size), (cx - size * 0.9, cy + size * 0.7),
           (cx + size * 0.9, cy + size * 0.7)]

    # spectrum fan emerging to the right
    spectrum = [(255, 60, 90), (255, 150, 40), (255, 230, 60),
                (70, 220, 130), (60, 170, 255), (150, 90, 255)]
    fan = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fan, "RGBA")
    ox, oy = cx + size * 0.5, cy + size * 0.05
    baseang = -12
    for i, col in enumerate(spectrum):
        a0 = math.radians(baseang + i * 6)
        a1 = math.radians(baseang + (i + 1) * 6 + 0.6)
        L = N * 0.9
        p0 = (ox + L * math.cos(a0), oy + L * math.sin(a0))
        p1 = (ox + L * math.cos(a1), oy + L * math.sin(a1))
        fd.polygon([(ox, oy), p0, p1], fill=(col[0], col[1], col[2], 200))
    fan = fan.filter(ImageFilter.GaussianBlur(N * 0.006))
    img.alpha_composite(fan)

    # incoming white beam from left
    beam = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bd = ImageDraw.Draw(beam, "RGBA")
    bd.polygon([(0, cy - N * 0.012), (0, cy + N * 0.012),
                (cx - size * 0.2, cy + N * 0.02), (cx - size * 0.2, cy - N * 0.02)],
               fill=(255, 255, 255, 230))
    beam = beam.filter(ImageFilter.GaussianBlur(N * 0.004))
    img.alpha_composite(beam)

    # glass prism (subtle translucent fill + bright edges)
    draw.polygon(tri, fill=(255, 255, 255, 26))
    draw.line(tri + [tri[0]], fill=(255, 255, 255, 210), width=int(N * 0.006), joint="curve")
    return img.convert("RGB")


# ---------------------------------------------------------------- concept 2
def concept_flow():
    """Luminous flowing ribbons — motion / living wallpaper."""
    img = diag_grad(N, (40, 12, 60), (10, 20, 60)).convert("RGBA")
    glow = radial_glow(N, (N * 0.35, N * 0.4), (120, 60, 200), N * 0.6, 0.5)
    img.alpha_composite(glow)

    ribbons = [((90, 220, 255), 0.0), ((180, 120, 255), 0.12),
               ((255, 120, 200), 0.24), ((120, 255, 200), 0.36)]
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer, "RGBA")
    for col, phase in ribbons:
        pts_top, pts_bot = [], []
        w = N * 0.05
        for i in range(0, N + 1, 8):
            x = i
            y = N * 0.5 + math.sin(i / N * math.pi * 2 + phase * 10) * N * 0.22 \
                + math.sin(i / N * math.pi * 5 + phase * 6) * N * 0.05
            pts_top.append((x, y - w))
            pts_bot.append((x, y + w))
        poly = pts_top + pts_bot[::-1]
        ld.polygon(poly, fill=(col[0], col[1], col[2], 150))
    layer = layer.filter(ImageFilter.GaussianBlur(N * 0.004))
    img.alpha_composite(layer)
    return img.convert("RGB")


# ---------------------------------------------------------------- concept 3
def concept_aperture():
    """Concentric offset arcs forming a portal / aperture into a living scene."""
    img = vgrad(N, (12, 14, 24), (4, 4, 10)).convert("RGBA")
    cx, cy = N * 0.5, N * 0.5
    glow = radial_glow(N, (cx, cy), (60, 120, 255), N * 0.42, 0.9)
    img.alpha_composite(glow)

    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer, "RGBA")
    rings = [(N * 0.34, (90, 200, 255)), (N * 0.27, (150, 120, 255)),
             (N * 0.20, (255, 120, 200)), (N * 0.13, (255, 220, 120))]
    for i, (r, col) in enumerate(rings):
        off = i * N * 0.018
        bbox = [cx - r + off, cy - r + off, cx + r + off, cy + r + off]
        start = 30 + i * 40
        ld.arc(bbox, start, start + 270, fill=(col[0], col[1], col[2], 255),
               width=int(N * 0.02))
    # bright core
    cr = N * 0.05
    ld.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=(255, 255, 255, 240))
    layer = layer.filter(ImageFilter.GaussianBlur(N * 0.002))
    img.alpha_composite(layer)
    return img.convert("RGB")


CONCEPTS = {"1-prism": concept_prism, "2-flow": concept_flow, "3-aperture": concept_aperture}
mask = squircle_mask(N)

thumbs = []
for name, fn in CONCEPTS.items():
    art = fn().convert("RGBA")
    art.putalpha(mask)
    art = art.resize((S, S), Image.LANCZOS)
    art.save(f"{OUT}/concept_{name}.png")
    thumbs.append((name, art))

# contact sheet
pad = 40
tw = 360
sheet = Image.new("RGB", (tw * 3 + pad * 4, tw + pad * 2), (26, 26, 30))
for i, (name, art) in enumerate(thumbs):
    t = art.resize((tw, tw), Image.LANCZOS)
    bg = Image.new("RGB", (tw, tw), (26, 26, 30))
    bg.paste(t, (0, 0), t)
    sheet.paste(bg, (pad + i * (tw + pad), pad))
sheet.save(f"{OUT}/concepts_contact.png")
print("done")
