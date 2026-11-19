"""Combine per-clip contact sheets into a few montages for fast bulk review.

Reviewing 34 sheets individually is slow; this stacks them into grids of 6 with
an index strip so each montage can be checked in one look.
"""
from pathlib import Path

from PIL import Image, ImageDraw

SRC = Path(__file__).with_name("_verify_all")
OUT = Path(__file__).with_name("_montage")
PER_PAGE = 6
LABEL_H = 14


def main() -> None:
    OUT.mkdir(exist_ok=True)
    sheets = sorted(SRC.glob("*.jpg"))
    for page in range((len(sheets) + PER_PAGE - 1) // PER_PAGE):
        chunk = sheets[page * PER_PAGE:(page + 1) * PER_PAGE]
        imgs = [Image.open(p) for p in chunk]
        w = max(i.width for i in imgs)
        h = sum(i.height + LABEL_H for i in imgs)
        canvas = Image.new("RGB", (w, h), "black")
        draw = ImageDraw.Draw(canvas)
        y = 0
        for p, im in zip(chunk, imgs):
            draw.text((4, y + 2), p.stem[:150], fill="yellow")
            y += LABEL_H
            canvas.paste(im, (0, y))
            y += im.height
        out = OUT / f"page{page}.jpg"
        canvas.save(out, quality=88)
        print(f"  {out.name}: {len(chunk)} clips")


if __name__ == "__main__":
    main()
