#!/usr/bin/env python3
"""Generates raid's board art.

Committed so the assets are reproducible rather than mysterious, in the same
spirit as paintbot's scripts/art/*.py. Everything is painted procedurally from
a foundry palette: scorched stone with a cast-iron rim for the floor, a
smelter-golem rig with a glowing crucible chest for SMELTER-9, a chitinous
crawler, three role-coloured cog rigs, a slag pool decal, a telegraph ring and
a riveted pillar face.

    python3 scripts/art/gen_raid_art.py [outdir]

Default outdir is data/art. No downloads, no external assets: the bundle stays
hermetic.
"""

import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

PALETTE = {
    "stone_dark": (44, 30, 24),
    "stone": (74, 54, 42),
    "stone_light": (104, 78, 60),
    "scorch": (30, 20, 16),
    "iron": (92, 82, 78),
    "iron_dark": (48, 42, 40),
    "ember": (214, 84, 31),
    "ember_hot": (255, 176, 58),
    "slag": (201, 84, 31),
    "tank": (75, 123, 236),
    "healer": (46, 204, 113),
    "dps": (242, 193, 78),
    "boss": (214, 48, 49),
    "add": (141, 110, 99),
}


def noise_layer(size, seed, scale=1.0):
    rng = random.Random(seed)
    layer = Image.new("L", size)
    pixels = layer.load()
    for y in range(size[1]):
        for x in range(size[0]):
            pixels[x, y] = int(rng.random() * 255 * scale)
    return layer.filter(ImageFilter.GaussianBlur(1.2))


def floor_foundry(path, size=768):
    """Scorched foundry stone with a cast-iron rim and cooling channels."""
    img = Image.new("RGB", (size, size), PALETTE["stone_dark"])
    draw = ImageDraw.Draw(img)
    rng = random.Random(20260823)
    # slabs
    step = size // 8
    for gy in range(0, size, step):
        for gx in range(0, size, step):
            shade = rng.randint(-16, 16)
            base = PALETTE["stone"]
            draw.rectangle(
                [gx, gy, gx + step - 2, gy + step - 2],
                fill=tuple(max(0, min(255, c + shade)) for c in base),
            )
    # scorch blooms
    for _ in range(90):
        cx = rng.randint(0, size)
        cy = rng.randint(0, size)
        r = rng.randint(12, 70)
        overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=PALETTE["scorch"] + (rng.randint(20, 70),),
        )
        img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    # cooling channels, glowing faintly
    draw = ImageDraw.Draw(img, "RGBA")
    for i in range(6):
        angle = i * math.pi / 6 + 0.3
        x0 = size / 2 + math.cos(angle) * size * 0.48
        y0 = size / 2 + math.sin(angle) * size * 0.48
        x1 = size / 2 - math.cos(angle) * size * 0.48
        y1 = size / 2 - math.sin(angle) * size * 0.48
        draw.line([x0, y0, x1, y1], fill=PALETTE["iron_dark"] + (150,), width=7)
        draw.line([x0, y0, x1, y1], fill=PALETTE["ember"] + (55,), width=2)
    # grain
    grain = noise_layer((size, size), 7, 0.35).convert("RGB")
    img = Image.blend(img, grain, 0.10)
    # cast-iron rim
    draw = ImageDraw.Draw(img, "RGBA")
    for width, colour in ((22, PALETTE["iron_dark"]), (10, PALETTE["iron"])):
        draw.ellipse([width // 2, width // 2, size - width // 2, size - width // 2],
                     outline=colour + (255,), width=width)
    img.save(path, quality=88)


def boss_smelter(path, size=128):
    """A squat smelter golem with a crucible chest that brightens per phase."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    c = size / 2
    # shadow
    draw.ellipse([c - 46, size - 26, c + 46, size - 6], fill=(0, 0, 0, 90))
    # legs
    draw.polygon([(c - 34, size - 14), (c - 18, size - 60), (c - 4, size - 14)],
                 fill=PALETTE["iron_dark"] + (255,))
    draw.polygon([(c + 34, size - 14), (c + 18, size - 60), (c + 4, size - 14)],
                 fill=PALETTE["iron_dark"] + (255,))
    # body
    draw.rounded_rectangle([c - 40, 30, c + 40, size - 34], radius=12,
                           fill=PALETTE["iron"] + (255,),
                           outline=(28, 24, 22, 255), width=3)
    # crucible chest
    for r, colour in ((22, PALETTE["boss"]), (15, PALETTE["ember"]),
                      (8, PALETTE["ember_hot"])):
        draw.ellipse([c - r, 62 - r, c + r, 62 + r], fill=colour + (255,))
    # shoulders
    draw.rounded_rectangle([c - 54, 34, c - 34, 62], radius=6,
                           fill=PALETTE["iron_dark"] + (255,))
    draw.rounded_rectangle([c + 34, 34, c + 54, 62], radius=6,
                           fill=PALETTE["iron_dark"] + (255,))
    # head + eye slit
    draw.rounded_rectangle([c - 20, 8, c + 20, 34], radius=6,
                           fill=PALETTE["iron"] + (255,),
                           outline=(28, 24, 22, 255), width=3)
    draw.rectangle([c - 13, 18, c + 13, 24], fill=PALETTE["ember_hot"] + (255,))
    # rivets
    for x in range(int(c - 34), int(c + 35), 17):
        draw.ellipse([x - 2, 96, x + 2, 100], fill=(200, 180, 160, 210))
    img.save(path)


def add_crawler(path, size=32):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([3, 18, 29, 30], fill=(0, 0, 0, 70))
    for i in range(3):
        y = 12 + i * 5
        draw.line([4, y, 28, y + 2], fill=PALETTE["iron_dark"] + (255,), width=2)
    draw.ellipse([6, 8, 26, 26], fill=PALETTE["add"] + (255,),
                 outline=(38, 28, 22, 255), width=2)
    draw.ellipse([12, 12, 20, 18], fill=PALETTE["ember"] + (255,))
    draw.polygon([(6, 12), (0, 6), (8, 9)], fill=PALETTE["iron_dark"] + (255,))
    draw.polygon([(26, 12), (32, 6), (24, 9)], fill=PALETTE["iron_dark"] + (255,))
    img.save(path)


def cog(path, tint, badge, size=64):
    """A cog rig recoloured for its role, with a role badge overlay."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    c = size / 2
    draw.ellipse([c - 18, size - 16, c + 18, size - 4], fill=(0, 0, 0, 90))
    # legs
    draw.rectangle([c - 12, 40, c - 4, 56], fill=PALETTE["iron_dark"] + (255,))
    draw.rectangle([c + 4, 40, c + 12, 56], fill=PALETTE["iron_dark"] + (255,))
    # torso
    draw.rounded_rectangle([c - 16, 18, c + 16, 44], radius=7,
                           fill=tint + (255,), outline=(24, 20, 18, 255), width=2)
    # head
    draw.ellipse([c - 11, 4, c + 11, 26], fill=tuple(min(255, v + 40) for v in tint) + (255,),
                 outline=(24, 20, 18, 255), width=2)
    draw.rectangle([c - 7, 12, c + 7, 16], fill=(20, 16, 14, 255))
    if badge == "pauldron":
        draw.rounded_rectangle([c - 24, 18, c - 12, 32], radius=4,
                               fill=(200, 210, 230, 255), outline=(24, 20, 18, 255), width=2)
        draw.rounded_rectangle([c + 12, 18, c + 24, 32], radius=4,
                               fill=(200, 210, 230, 255), outline=(24, 20, 18, 255), width=2)
        for y in (22, 28):
            draw.ellipse([c - 20, y, c - 17, y + 3], fill=(90, 100, 120, 255))
            draw.ellipse([c + 17, y, c + 20, y + 3], fill=(90, 100, 120, 255))
    elif badge == "canister":
        draw.rounded_rectangle([c + 12, 22, c + 22, 42], radius=4,
                               fill=(230, 245, 235, 255), outline=(24, 20, 18, 255), width=2)
        draw.rectangle([c + 15, 26, c + 19, 38], fill=PALETTE["healer"] + (255,))
    else:
        draw.polygon([(c + 14, 20), (c + 26, 30), (c + 14, 40)],
                     fill=(240, 230, 210, 255), outline=(24, 20, 18, 255))
    img.save(path)


def pool_decal(path, size=256):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    rng = random.Random(4242)
    for i in range(7):
        r = size // 2 - i * 8
        alpha = 60 + i * 22
        colour = (
            min(255, PALETTE["slag"][0] + i * 6),
            max(0, PALETTE["slag"][1] - i * 4),
            max(0, PALETTE["slag"][2] - i * 2),
        )
        draw.ellipse([size / 2 - r, size / 2 - r, size / 2 + r, size / 2 + r],
                     fill=colour + (alpha,))
    for _ in range(40):
        a = rng.random() * math.tau
        d = rng.random() * size * 0.4
        x = size / 2 + math.cos(a) * d
        y = size / 2 + math.sin(a) * d
        r = rng.randint(3, 11)
        draw.ellipse([x - r, y - r, x + r, y + r],
                     fill=PALETTE["ember_hot"] + (rng.randint(50, 130),))
    img = img.filter(ImageFilter.GaussianBlur(2.0))
    img.save(path)


def telegraph_ring(path, size=256):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([6, 6, size - 6, size - 6], outline=(255, 190, 110, 235), width=9)
    draw.ellipse([16, 16, size - 16, size - 16], outline=(255, 120, 40, 150), width=3)
    for i in range(0, size, 16):
        draw.line([i, 0, 0, i], fill=(255, 150, 60, 40), width=2)
        draw.line([size - i, size, size, size - i], fill=(255, 150, 60, 40), width=2)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse([2, 2, size - 2, size - 2], fill=255)
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", img.size, 0), mask))
    img.save(path)


def pillar(path, size=128):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, size, size], fill=PALETTE["iron"] + (255,))
    for y in range(0, size, 16):
        draw.line([0, y, size, y], fill=PALETTE["iron_dark"] + (255,), width=3)
    for y in range(8, size, 16):
        for x in range(10, size, 26):
            draw.ellipse([x, y, x + 5, y + 5], fill=(196, 180, 164, 255))
    draw.rectangle([0, 0, size - 1, size - 1], outline=(22, 18, 16, 255), width=4)
    img.save(path)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "art")
    os.makedirs(outdir, exist_ok=True)
    floor_foundry(os.path.join(outdir, "floor_foundry.jpg"))
    boss_smelter(os.path.join(outdir, "boss_smelter.png"))
    add_crawler(os.path.join(outdir, "add_crawler.png"))
    cog(os.path.join(outdir, "cog_tank.png"), PALETTE["tank"], "pauldron")
    cog(os.path.join(outdir, "cog_healer.png"), PALETTE["healer"], "canister")
    cog(os.path.join(outdir, "cog_dps.png"), PALETTE["dps"], "blade")
    pool_decal(os.path.join(outdir, "pool.png"))
    telegraph_ring(os.path.join(outdir, "telegraph_ring.png"))
    pillar(os.path.join(outdir, "pillar.png"))
    print("raid art written to", outdir)


if __name__ == "__main__":
    main()
