#!/usr/bin/env python3
"""Draws the app icon (an original design: a crosshair over a dark plate with "1.6")."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
out = sys.argv[1] if len(sys.argv) > 1 else 'AppIcon-1024.png'
font_path = sys.argv[2] if len(sys.argv) > 2 else '/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf'

# background: dark steel radial gradient
bg = Image.new('RGB', (S, S))
px = bg.load()
cx, cy = S * 0.5, S * 0.42
for y in range(S):
    for x in range(S):
        d = math.hypot(x - cx, y - cy) / (S * 0.75)
        t = min(1.0, d)
        r = int(46 * (1 - t) + 14 * t)
        g = int(52 * (1 - t) + 16 * t)
        b = int(58 * (1 - t) + 19 * t)
        px[x, y] = (r, g, b)

# faint diagonal hazard stripes in the lower band
stripes = Image.new('L', (S, S), 0)
sd = ImageDraw.Draw(stripes)
for i in range(-S, 2 * S, 90):
    sd.polygon([(i, S), (i + 45, S), (i + 45 + 260, S - 260), (i + 260, S - 260)], fill=22)
band = Image.new('L', (S, S), 0)
ImageDraw.Draw(band).rectangle([0, S - 260, S, S], fill=255)
stripes = Image.composite(stripes, Image.new('L', (S, S), 0), band)
bg = Image.composite(Image.new('RGB', (S, S), (255, 170, 40)), bg, stripes)

# crosshair layer
GREEN = (70, 255, 110)
layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
ccx, ccy = S // 2, int(S * 0.355)
gap, length, thick = 58, 150, 32
for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
    x0 = ccx + dx * gap
    y0 = ccy + dy * gap
    x1 = ccx + dx * (gap + length)
    y1 = ccy + dy * (gap + length)
    if dx:
        d.rounded_rectangle([min(x0, x1), ccy - thick // 2, max(x0, x1), ccy + thick // 2], radius=10, fill=GREEN + (255,))
    else:
        d.rounded_rectangle([ccx - thick // 2, min(y0, y1), ccx + thick // 2, max(y0, y1)], radius=10, fill=GREEN + (255,))
d.ellipse([ccx - 13, ccy - 13, ccx + 13, ccy + 13], fill=GREEN + (255,))

# glow under the crosshair
glow = layer.filter(ImageFilter.GaussianBlur(28))
img = bg.convert('RGBA')
img = Image.alpha_composite(img, glow)
img = Image.alpha_composite(img, glow)
img = Image.alpha_composite(img, layer)

# "1.6" label
font = ImageFont.truetype(font_path, 230)
text = '1.6'
td = ImageDraw.Draw(img)
bbox = td.textbbox((0, 0), text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
tx = (S - tw) // 2 - bbox[0]
ty = int(S * 0.745) - bbox[1] - th // 2
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).text((tx + 8, ty + 10), text, font=font, fill=(0, 0, 0, 200))
img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(10)))
ImageDraw.Draw(img).text((tx, ty), text, font=font, fill=(245, 245, 240, 255))

img.convert('RGB').save(out)
print('wrote', out)
