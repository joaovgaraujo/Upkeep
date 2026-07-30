# make_icon.py - generates the Upkeep logo/icon set.
# Design: dark rounded tile, green circular "cycle" arrow (updates) with an
# arrowhead, white checkmark in the center (kept healthy / done).
# Outputs:
#   assets/logo.png          512px logo for README/branding
#   gui/assets/upkeep.ico    multi-size Windows icon (16..256)
#   gui/assets/icon_64.rgba  raw RGBA bytes for the eframe window icon
import math
import os

from PIL import Image, ImageDraw

S = 1024  # master canvas, downscaled for exports (supersampling)

BG = (30, 33, 48, 255)  # dark slate tile
RING = (74, 222, 128, 255)  # green cycle arrow
CHECK = (240, 244, 255, 255)  # near-white checkmark

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- rounded tile ---
radius = int(S * 0.22)
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=BG)

# --- circular arrow (arc with round caps + arrowhead) ---
cx = cy = S / 2
r = S * 0.315
ring_w = int(S * 0.085)

# PIL angles: 0 = 3 o'clock, increasing CLOCKWISE (y axis points down).
# The ring is rendered via a mask (pieslice donut + round caps + arrowhead)
# because ImageDraw.arc leaves seam notches at the ends of wide arcs.
start_deg, end_deg = -60.0, 200.0  # arc clockwise start->end; gap 200..300


def on_circle(deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)

# Donut sector: filled pie slice, inner disc punched out
outer = [cx - r - ring_w / 2, cy - r - ring_w / 2, cx + r + ring_w / 2, cy + r + ring_w / 2]
inner = [cx - r + ring_w / 2, cy - r + ring_w / 2, cx + r - ring_w / 2, cy + r - ring_w / 2]
md.pieslice(outer, start=start_deg, end=end_deg, fill=255)
md.ellipse(inner, fill=0)

# Round caps at both ends
for deg in (start_deg, end_deg):
    x, y = on_circle(deg)
    md.ellipse([x - ring_w / 2, y - ring_w / 2, x + ring_w / 2, y + ring_w / 2], fill=255)

# Arrowhead at the arc END, pointing clockwise (into the gap). Tangent of
# increasing PIL angle at t is (-sin t, cos t).
a = math.radians(end_deg)
pos = on_circle(end_deg)
tang = (-math.sin(a), math.cos(a))
rad = (math.cos(a), math.sin(a))
head_len = ring_w * 2.2
head_w = ring_w * 1.15
p_tip = (pos[0] + tang[0] * head_len, pos[1] + tang[1] * head_len)
p_a = (pos[0] + rad[0] * head_w, pos[1] + rad[1] * head_w)
p_b = (pos[0] - rad[0] * head_w, pos[1] - rad[1] * head_w)
md.polygon([p_tip, p_a, p_b], fill=255)

ring_layer = Image.new("RGBA", (S, S), RING)
img.paste(ring_layer, (0, 0), mask)

# --- checkmark ---
ck_w = int(S * 0.095)
p1 = (S * 0.345, S * 0.52)
p2 = (S * 0.465, S * 0.645)
p3 = (S * 0.685, S * 0.385)
d.line([p1, p2], fill=CHECK, width=ck_w)
d.line([p2, p3], fill=CHECK, width=ck_w)
for p in (p1, p2, p3):
    d.ellipse([p[0] - ck_w / 2, p[1] - ck_w / 2, p[0] + ck_w / 2, p[1] + ck_w / 2], fill=CHECK)

# --- exports ---
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
gui_assets = os.path.join(root, "gui", "assets")
os.makedirs(gui_assets, exist_ok=True)

logo = img.resize((512, 512), Image.LANCZOS)
logo.save(os.path.join(here, "logo.png"))

ico_sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)]
img.resize((256, 256), Image.LANCZOS).save(
    os.path.join(gui_assets, "upkeep.ico"), format="ICO", sizes=ico_sizes
)

rgba64 = img.resize((64, 64), Image.LANCZOS)
with open(os.path.join(gui_assets, "icon_64.rgba"), "wb") as f:
    f.write(rgba64.tobytes())

print("logo.png, upkeep.ico, icon_64.rgba written")
