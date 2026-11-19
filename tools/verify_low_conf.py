"""Render contact sheets for the least-confident planned moves, for eyeballing."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc
from contact_sheet import sheet

TARGETS = [
    ("Desktop", "rb Jul 04 05.49 PM.mp4"),                 # eldenring 67%
    ("Notepad", "rb Aug 03 11.06 PM.mp4"),                 # SpeciesUnknown 67%
    ("Desktop", "rb Jul 25 05.39 PM_trim_589-598.mp4"),    # eldenring 71%
    ("Desktop", "rb Jul 04 05.29 PM.mp4"),                 # eldenring 79%
    ("Desktop", "rb Jul 21 12.06 AM.mp4"),                 # eldenring 79%
    ("ApplicationFrameHost", "rb Jul 07 12.04 AM.mp4"),    # SonsOfTheForest 88%
    ("Discord", "rb Aug 01 04.36 PM.mp4"),                 # kept, 38%
]

outdir = Path(__file__).with_name("_verify")
outdir.mkdir(exist_ok=True)
for i, (folder, name) in enumerate(TARGETS):
    p = sc.VIDEOS / folder / name
    if p.exists():
        sheet(p, outdir / f"{i:02d}_{folder}_{p.stem[:26]}.jpg")
    else:
        print(f"  missing: {p}")
print(f"\nwrote sheets to {outdir}")
