"""Build a contact sheet for a clip so a human can eyeball the classification.

Trust but verify: the plan is only as good as the labels, so this renders the
frames the classifier actually voted on.
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc

COLS = 6


def sheet(path: Path, out: Path, n: int = 12) -> None:
    frames = sc.grab_frames(path, n)
    if not frames:
        print(f"  no frames: {path}")
        return
    w, h = frames[0].size
    rows = (len(frames) + COLS - 1) // COLS
    canvas = Image.new("RGB", (w * COLS, h * rows), "black")
    for i, f in enumerate(frames):
        canvas.paste(f, ((i % COLS) * w, (i // COLS) * h))
    canvas.save(out)
    print(f"  {out.name}  <- {path.parent.name}\\{path.name}")


if __name__ == "__main__":
    outdir = Path(__file__).with_name("_verify")
    outdir.mkdir(exist_ok=True)
    for i, arg in enumerate(sys.argv[1:]):
        p = Path(arg)
        sheet(p, outdir / f"{i:02d}_{p.parent.name}_{p.stem[:28]}.jpg")
