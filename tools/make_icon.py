#!/usr/bin/env python3
"""Значок Ваджра-трекера: золотая ваджра со свечением на изумрудном фоне. → icon-512.png, icon-192.png, icon-180.png"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLD, GOLD_HI, GOLD_LO = (236, 196, 110), (255, 232, 170), (176, 128, 52)
CRIMSON = (192, 24, 90)
K = 0.88                                             # масштаб рисунка: острия в безопасной зоне maskable


def bg(s):
    img = Image.new('RGB', (s, s))
    px = img.load()
    c = s / 2
    for y in range(s):
        for x in range(s):
            t = min(1, math.hypot(x - c, y - c * 0.9) / (s * 0.75))   # радиальный: центр светлее
            px[x, y] = (int(22 - 14 * t), int(96 - 60 * t), int(76 - 48 * t))
    return img.convert('RGBA')


def half(d, s, sign):
    """Половина ваджры: лотос-бутон + 5 зубцов, сходящихся к острию. sign=-1 вверх, +1 вниз."""
    c = s / 2
    u = s / 100 * K
    y = lambda v: c + sign * v * u
    # лотосовая «чаша» у центра
    d.polygon([(c - 9 * u, y(5)), (c + 9 * u, y(5)), (c + 6 * u, y(11)), (c - 6 * u, y(11))], fill=GOLD_LO)
    d.ellipse([c - 7 * u, min(y(10), y(15)), c + 7 * u, max(y(10), y(15))], fill=GOLD)
    # боковые зубцы — дуги от бутона к острию
    tip = y(38)
    for k, w in ((-1, 15), (1, 15), (-1, 8.5), (1, 8.5)):
        pts = []
        for i in range(41):
            t = i / 40
            yy = y(13 + t * 22)
            xx = c + k * w * u * math.sin(math.pi * (0.15 + 0.85 * t) * 0.95) * (1 - t ** 3)
            pts.append((xx, yy))
        pts.append((c, tip))
        d.line(pts, fill=GOLD if abs(w) > 9 else GOLD_HI, width=int(2.6 * u), joint='curve')
    # центральный зубец и острие
    d.line([(c, y(13)), (c, tip)], fill=GOLD_HI, width=int(3.2 * u))
    d.polygon([(c - 2.6 * u, y(33)), (c + 2.6 * u, y(33)), (c, y(41))], fill=GOLD_HI)


def draw(size):
    s = size * 4
    img = bg(s)
    art = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    u = s / 100 * K
    c = s / 2
    half(d, s, -1)
    half(d, s, +1)
    # центральная сфера — малиновая, как в самом трекере, с золотым ободком
    r = 6.5 * u
    d.ellipse([c - r - 1.4 * u, c - r - 1.4 * u, c + r + 1.4 * u, c + r + 1.4 * u], fill=GOLD)
    d.ellipse([c - r, c - r, c + r, c + r], fill=CRIMSON)
    d.ellipse([c - r * .45 - r * .3, c - r * .45 - r * .3, c - r * .45 + r * .3, c - r * .45 + r * .3], fill=(250, 170, 200))
    glow = art.filter(ImageFilter.GaussianBlur(s / 28))
    halo = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse([c - 30 * u, c - 30 * u, c + 30 * u, c + 30 * u], fill=(255, 214, 130, 40))
    halo = halo.filter(ImageFilter.GaussianBlur(s / 12))
    img = Image.alpha_composite(img, halo)
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, art)
    return img.resize((size, size), Image.LANCZOS).convert('RGB')


if __name__ == '__main__':
    big = draw(512)
    big.save(os.path.join(HERE, 'icon-512.png'))
    for n in (192, 180):
        big.resize((n, n), Image.LANCZOS).save(os.path.join(HERE, 'icon-%d.png' % n))
    print('ok')
