#!/usr/bin/env python3
"""
Forge koru's visual identity: albedo (background.png) + exact depth (background_depth.png).

Not an AI image — a *computed* one. "koru" is the Maori unfurling silver-fern
frond: a logarithmic spiral. We draw that frond as a luminous jade tendril on a
deep forest-black field, and derive the depth map from the SAME height field the
frond is drawn from, so albedo and depth are pixel-perfectly registered. The
depth is exact (the frond genuinely floats above the field), not estimated —
which is the whole parallax point, and very koru: precision, no compromise.

Depth convention: white = near (max parallax), black = far — MiDaS/Cordial style.
"""
import numpy as np
from PIL import Image, ImageFilter

W, H = 1920, 1200

# ---- palette (must match visual-identity.json) ----
BASE   = np.array([0x0B, 0x0F, 0x0D], float)   # forest-black
ACCENT = np.array([0x35, 0xE2, 0x9F], float)   # unfurling jade
CORE   = np.array([0xEC, 0xFF, 0xF6], float)   # luminous frond core (near-white jade)

# ---- spiral geometry ----
# Off-centre for composition (frond curls toward lower-right third).
cx, cy = 0.615 * W, 0.47 * H
r_min  = 7.0                      # tight inner curl radius (px)
r_max  = 0.36 * H                 # outer reach (px)
turns  = 2.85                     # how many times the frond wraps
theta_max = turns * 2 * np.pi
# handedness: unfurl anticlockwise, rotate so the cut stem hangs down-ish
phase = np.deg2rad(20.0)

N = 1400
t = np.linspace(0.0, 1.0, N)                     # 0 = tight centre, 1 = outer stem
theta = t * theta_max
r = r_min * (r_max / r_min) ** t                  # logarithmic spiral
xs = cx + r * np.cos(theta + phase)
ys = cy + r * np.sin(theta + phase)

# frond half-thickness: thin at the curl, thickening toward the outer base,
# then tapering back to a soft point at the very end (a cut fern stem).
base_thick = 3.0 + 30.0 * (t ** 1.15)
end_taper  = np.clip((1.0 - t) / 0.06, 0.0, 1.0)  # last ~6% tapers off
end_taper  = 0.35 + 0.65 * end_taper              # never fully zero except tip
thick = base_thick * np.where(t > 0.94, end_taper, 1.0)

# nearness along the frond: the tight centre curl sits nearest the viewer.
near = 1.0 - 0.45 * t

Hf = np.zeros((H, W), float)   # height / depth of the frond
Gf = np.zeros((H, W), float)   # jade glow field
Sf = np.zeros((H, W), float)   # solid frond coverage (for the bright core)

yy, xx = np.mgrid[0:H, 0:W]

for i in range(N):
    x0, y0, rr, nn = xs[i], ys[i], thick[i], near[i]
    glow_r = rr * 2.4 + 10.0
    pad = int(glow_r + 3)
    ix0, ix1 = max(0, int(x0 - pad)), min(W, int(x0 + pad) + 1)
    iy0, iy1 = max(0, int(y0 - pad)), min(H, int(y0 + pad) + 1)
    if ix0 >= ix1 or iy0 >= iy1:
        continue
    sx = xx[iy0:iy1, ix0:ix1] - x0
    sy = yy[iy0:iy1, ix0:ix1] - y0
    dist = np.sqrt(sx * sx + sy * sy)
    # solid frond with ~1.6px soft edge
    solid = np.clip((rr - dist) / 1.6 + 0.5, 0.0, 1.0)
    Sf[iy0:iy1, ix0:ix1] = np.maximum(Sf[iy0:iy1, ix0:ix1], solid)
    Hf[iy0:iy1, ix0:ix1] = np.maximum(Hf[iy0:iy1, ix0:ix1], nn * solid)
    # gaussian glow around the frond
    glow = np.exp(-(dist * dist) / (2.0 * (rr * 1.15 + 4.0) ** 2))
    Gf[iy0:iy1, ix0:ix1] = np.maximum(Gf[iy0:iy1, ix0:ix1], glow)

# small filled "eye" bulb at the very centre of the curl (the koru's heart)
d_eye = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
eye = np.clip((r_min * 1.9 - d_eye) / 2.0 + 0.5, 0.0, 1.0)
Sf = np.maximum(Sf, eye)
Hf = np.maximum(Hf, 1.0 * eye)
Gf = np.maximum(Gf, np.exp(-(d_eye ** 2) / (2.0 * (r_min * 2.6) ** 2)))

# ---- background field: subtle radial atmosphere + faint spores ----
rng = np.random.default_rng(114107114117)  # seeded by ord('r','o','r','u')? just koru bytes
# large soft jade nebula behind the spiral
neb = np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2)) / (2.0 * (0.42 * H) ** 2))
# vignette toward the corners
vig = 1.0 - 0.55 * (((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
vig = np.clip(vig, 0.35, 1.0)

# faint bokeh spores (drifting fern spores)
spore = np.zeros((H, W), float)
for _ in range(90):
    px, py = rng.uniform(0, W), rng.uniform(0, H)
    pr = rng.uniform(1.5, 5.0)
    pi = rng.uniform(0.05, 0.28)
    ex0, ex1 = max(0, int(px - pr * 4)), min(W, int(px + pr * 4))
    ey0, ey1 = max(0, int(py - pr * 4)), min(H, int(py + pr * 4))
    d = np.sqrt((xx[ey0:ey1, ex0:ex1] - px) ** 2 + (yy[ey0:ey1, ex0:ex1] - py) ** 2)
    spore[ey0:ey1, ex0:ex1] += pi * np.exp(-(d * d) / (2.0 * pr * pr))
spore = np.clip(spore, 0.0, 0.5)

# ---- compose ALBEDO ----
img = np.empty((H, W, 3), float)
for c in range(3):
    img[:, :, c] = BASE[c] * vig
# jade nebula lift
img += (ACCENT * 0.10)[None, None, :] * neb[:, :, None]
# frond glow -> accent
img += (ACCENT)[None, None, :] * (Gf ** 1.25)[:, :, None] * 0.85
# bright luminous core on the solid frond
core_line = np.clip(Sf - 0.15, 0.0, 1.0)
img += (CORE - ACCENT)[None, None, :] * (core_line ** 2.2)[:, :, None] * 0.7
# spores in jade
img += (ACCENT * 0.9)[None, None, :] * spore[:, :, None]
img = np.clip(img, 0, 255).astype(np.uint8)
alb = Image.fromarray(img, "RGB")
alb = alb.filter(ImageFilter.GaussianBlur(0.4))
alb.save("background.png", optimize=True)

# ---- compose DEPTH (exact, registered) ----
# background: gentle bowl, centre slightly nearer than the far corners
bg_depth = 0.10 + 0.14 * neb
# frond ridge sits well above the field; smooth it a touch for tear-free parallax
frond = Hf.copy()
depth = np.maximum(bg_depth, 0.35 + 0.65 * frond)
depth = np.where(frond > 0.01, depth, bg_depth)
dimg = Image.fromarray((np.clip(depth, 0, 1) * 255).astype(np.uint8), "L")
dimg = dimg.filter(ImageFilter.GaussianBlur(1.1))   # soft depth = smooth parallax
dimg.save("background_depth.png", optimize=True)

print("forged background.png (albedo) + background_depth.png (depth)")
print(f"  size {W}x{H}  spiral turns={turns}  centre=({cx:.0f},{cy:.0f})")
