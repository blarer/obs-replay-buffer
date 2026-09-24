"""Classify misfiled OBS clips by what is actually on screen.

The correctly-sorted folders (eldenring, FortniteClient-..., etc.) are labeled
ground truth. We sample frames from them to build a per-game reference set, then
sample frames from each misfiled clip and vote.

Deliberately dependency-light: ffmpeg + numpy + PIL, no ML runtime. Each frame
becomes a downsampled color-layout + edge-density signature, which is enough to
separate visually distinct games and UIs.

Voting mirrors the OBS script: a clip is labeled by the game that dominates its
frames, so passing through Discord at the end does not decide the folder.

Usage:
  python sort_clips.py scan          # build reference fingerprints (cached)
  python sort_clips.py plan          # classify misfiled clips, print a plan
  python sort_clips.py apply         # execute the plan (moves files)
  python sort_clips.py verify FILE   # dump per-frame votes for one file
"""
from __future__ import annotations

import io
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

VIDEOS = Path(r"C:\Users\blare\Videos")
CACHE = VIDEOS / ".clipsort-cache.json"
PROGRESS = Path(__file__).with_name("clipsort-progress.log")


def log(msg: str) -> None:
    """Print and append to a log file: stdout can be buffered by the caller."""
    print(msg)
    with PROGRESS.open("a", encoding="utf-8") as fh:
        fh.write(msg + "\n")

# Folders that are trustworthy labels: the app was genuinely on screen.
# "Desktop" and "Dead Space" are seeded from hand-verified clips (see
# REFERENCE_OVERRIDES) rather than whole folders, because those folders are
# themselves a mix.
REFERENCE_FOLDERS = [
    "eldenring",
    "FortniteClient-Win64-Shipping",
    "SonsOfTheForest",
    "Reanimal",
    "SpeciesUnknown-Win64-Shipping",
]

# Hand-verified examples for classes that cannot be taken from a folder wholesale.
# Without a "Desktop" class, desktop footage has nowhere to land and gets forced
# into the nearest game, which was the single biggest source of error in review.
REFERENCE_OVERRIDES = {
    "Desktop": [
        ("Desktop", "rb Jul 04 05.29 PM.mp4"),          # IDE / dark UI throughout
        ("Desktop", "rb Jul 04 05.28 PM.mp4"),          # IDE / dark UI throughout
        ("Discord", "rb Jul 23 06.20 PM.mp4"),          # Win11 desktop + explorer
        ("Discord", "rb Aug 01 04.36 PM.mp4"),          # Discord over wallpaper
        ("Notepad", "rb Aug 03 11.06 PM.mp4"),          # editor + Discord
    ],
    "Dead Space": [
        ("Dead Space", "rb Jul 04 05.31 PM.mp4"),
        ("Desktop", "rb Jul 04 05.49 PM.mp4"),          # verified Dead Space footage
    ],
}

# Folders whose contents are suspect and should be reclassified.
SUSPECT_FOLDERS = ["Desktop", "ApplicationFrameHost", "Discord", "Notepad"]

# Folders to leave completely alone.
SKIP_FOLDERS = {"Captures", "clips", "claude", ".clipsort-cache.json"}

GRID = 8            # edge-energy grid (GRID x GRID cells)
HUE_BINS = 16       # bins per HSV histogram channel
REF_FRAMES = 24     # frames sampled per reference video
TEST_FRAMES = 24    # frames sampled per clip under test
SEEK_WORKERS = 12   # parallel ffmpeg seeks (9950X3D has plenty of cores)
KNN = 3             # per-frame label distance = mean of its 3 nearest ref frames

# Tuned by leave-one-video-out over the reference library (see accuracy_big.py).
# On classes with >= 3 example videos: 96% accuracy, 98% precision when it
# commits at 0.60. Higher thresholds abstain more; a wrong move is worse than
# leaving a file where it is, so this errs toward abstaining.
MIN_CONFIDENCE = 0.60   # dominant-label vote share required to move a file
MIN_REF_VIDEOS = 3      # classes with fewer examples are not trustworthy targets


# ----------------------------------------------------------------- ffmpeg ---

def duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def _grab_one(path: Path, t: float) -> Image.Image | None:
    """Grab a single frame at time t using input-side (fast) seek."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", f"{t:.2f}", "-i", str(path),
         "-frames:v", "1", "-vf", "scale=160:-1",
         "-f", "image2pipe", "-vcodec", "bmp", "-"],
        capture_output=True)
    if out.returncode != 0 or not out.stdout:
        return None
    frames = _split_bmp_stream(out.stdout)
    return frames[0] if frames else None


def grab_frames(path: Path, n: int) -> list[Image.Image]:
    """Sample n frames spread evenly across the video, skipping the edges.

    Uses input-side seeks (`-ss` before `-i`), which jump straight to the
    nearest keyframe instead of decoding from the start. A sequential decode of
    a 10 minute 4K clip takes ~3 minutes; a keyframe seek takes <1s. Seeks are
    issued in parallel since each is its own short-lived ffmpeg process.
    """
    dur = duration(path)
    if dur <= 0:
        return []
    # Skip the first/last 5%: loading screens and alt-tabs cluster there.
    times = np.linspace(dur * 0.05, dur * 0.95, n)
    with ThreadPoolExecutor(max_workers=SEEK_WORKERS) as ex:
        frames = list(ex.map(lambda t: _grab_one(path, float(t)), times))
    return [f for f in frames if f is not None]


def _split_bmp_stream(data: bytes) -> list[Image.Image]:
    """Split a concatenated BMP stream into images.

    BMP is used instead of PNG because encoding is trivially cheap and each
    file carries its total size in the header, so the stream is easy to split.
    """
    frames, i, n = [], 0, len(data)
    while i + 6 <= n and data[i:i + 2] == b"BM":
        size = int.from_bytes(data[i + 2:i + 6], "little")
        if size <= 0 or i + size > n:
            break
        try:
            frames.append(Image.open(io.BytesIO(data[i:i + size])).convert("RGB"))
        except Exception:
            pass
        i += size
    return frames


# ---------------------------------------------------------------- features ---

def signature(img: Image.Image) -> np.ndarray:
    """HSV histogram + spatial edge energy, L2-normalized.

    Chosen by comparing candidate features under leave-one-video-out (see
    search_features.py). A plain color-layout grid scored 78% because it keys on
    where things are on screen, which shifts between sessions. Histograms are
    position-invariant, so they survive camera movement and different maps, and
    edge energy adds the scene structure that separates a busy 3D game from flat
    UI. Together they reach 93% overall and 96% on well-represented classes.
    """
    a = np.asarray(img.resize((64, 36)), dtype=np.float32) / 255.0

    # --- HSV histograms (palette, position-invariant) ---
    mx = a.max(axis=2)
    mn = a.min(axis=2)
    d = mx - mn + 1e-8
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    hue = np.where(mx == r, (g - b) / d % 6,
          np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) / 6.0
    sat = d / (mx + 1e-8)

    # Hue is weighted by saturation so washed-out pixels do not vote on color.
    hh, _ = np.histogram(hue, bins=HUE_BINS, range=(0, 1), weights=sat)
    ss, _ = np.histogram(sat, bins=HUE_BINS, range=(0, 1))
    vv, _ = np.histogram(mx, bins=HUE_BINS, range=(0, 1))
    hist = np.concatenate([hh / max(hh.sum(), 1e-8),
                           ss / max(ss.sum(), 1e-8),
                           vv / max(vv.sum(), 1e-8)])
    hist /= max(np.linalg.norm(hist), 1e-8)

    # --- Spatial edge energy (scene structure: 3D scene vs flat UI) ---
    gray = a.mean(axis=2)
    gx = np.diff(gray, axis=1, prepend=gray[:, :1])
    gy = np.diff(gray, axis=0, prepend=gray[:1, :])
    mag = np.hypot(gx, gy)
    ch, cw = mag.shape[0] // GRID, mag.shape[1] // GRID
    edge = mag[:ch * GRID, :cw * GRID].reshape(GRID, ch, GRID, cw).mean(axis=(1, 3)).ravel()
    edge /= max(np.linalg.norm(edge), 1e-8)

    v = np.concatenate([hist, edge * 0.7])
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def video_signatures(path: Path, n: int) -> np.ndarray:
    frames = grab_frames(path, n)
    if not frames:
        return np.zeros((0, GRID * GRID * 4))
    return np.stack([signature(f) for f in frames])


# ------------------------------------------------------------- reference ---

def videos_in(folder: str) -> list[Path]:
    d = VIDEOS / folder
    if not d.is_dir():
        return []
    return sorted(p for p in d.iterdir()
                  if p.suffix.lower() in (".mp4", ".mkv", ".mov") and p.is_file())


def override_paths() -> dict[str, list[Path]]:
    """Resolve REFERENCE_OVERRIDES to existing files."""
    out = {}
    for label, entries in REFERENCE_OVERRIDES.items():
        paths = [VIDEOS / folder / name for folder, name in entries]
        paths = [p for p in paths if p.is_file()]
        if paths:
            out[label] = paths
    return out


def build_reference(force: bool = False) -> dict[str, np.ndarray]:
    cache = {}
    if CACHE.exists() and not force:
        raw = json.loads(CACHE.read_text())
        cache = {k: np.array(v, dtype=np.float32) for k, v in raw.items()}

    sources: dict[str, list[Path]] = {f: videos_in(f) for f in REFERENCE_FOLDERS}
    overrides = override_paths()
    sources.update(overrides)

    todo = [lab for lab, vids in sources.items() if lab not in cache and vids]
    for label in todo:
        vids = sources[label]
        # A folder-derived class needs several example videos before it
        # generalizes across sessions; with one example it tends to attract
        # unrelated clips. Overrides are hand-verified, so they are exempt.
        if label not in overrides and len(vids) < MIN_REF_VIDEOS:
            log(f"  skipping {label}: only {len(vids)} video(s), "
                f"need {MIN_REF_VIDEOS}")
            continue
        log(f"  fingerprinting {label} ({len(vids)} videos)...")
        # grab_frames already parallelizes seeks, so walk videos serially.
        sigs = [video_signatures(p, REF_FRAMES) for p in vids]
        sigs = [s for s in sigs if len(s)]
        if sigs:
            cache[label] = np.vstack(sigs).astype(np.float32)
            log(f"    {len(cache[label])} frames")

    if todo:
        CACHE.write_text(json.dumps({k: v.tolist() for k, v in cache.items()}))
    return cache


# ------------------------------------------------------------- classifying ---

def classify(path: Path, ref: dict[str, np.ndarray], frames: int = TEST_FRAMES):
    """Return (label, confidence, vote_breakdown) for one clip.

    Every frame votes for its nearest label, where "nearest" is the mean
    distance to that label's KNN closest reference frames. Using k>1 stops a
    single lucky frame match from carrying a whole video.

    Voting mirrors the OBS script's intent: the clip is labeled by whatever
    dominates its frames, so a few seconds of Discord at the end cannot decide
    the folder.
    """
    sigs = video_signatures(path, frames)
    if len(sigs) == 0:
        return None, 0.0, {}

    labels = list(ref.keys())
    votes: dict[str, int] = {}
    for s in sigs:
        best, best_d = None, 1e9
        for lab in labels:
            d = np.linalg.norm(ref[lab] - s, axis=1)
            k = min(KNN, len(d))
            dist = float(np.mean(np.partition(d, k - 1)[:k]))
            if dist < best_d:
                best, best_d = lab, dist
        votes[best] = votes.get(best, 0) + 1

    label = max(votes, key=votes.get)
    return label, votes[label] / len(sigs), votes


def suspect_files() -> list[Path]:
    """Clips eligible for reclassification.

    Files used as hand-verified reference examples are excluded: moving them
    would silently change the training set on the next run.
    """
    pinned = {p.resolve() for paths in override_paths().values() for p in paths}
    out = []
    for folder in SUSPECT_FOLDERS:
        out.extend(p for p in videos_in(folder) if p.resolve() not in pinned)
    return out


def make_plan(ref: dict[str, np.ndarray]) -> list[tuple[Path, str, float, dict]]:
    files = suspect_files()
    print(f"\nClassifying {len(files)} clips in {SUSPECT_FOLDERS}...\n")
    plan = []
    for p in files:
        label, conf, votes = classify(p, ref)
        cur = p.parent.name
        mark = "keep"
        if label and conf >= MIN_CONFIDENCE and label != cur:
            mark = f"-> {label}"
        print(f"  {cur:<22} {p.name:<42} {str(label):<32} {conf:5.0%}  {mark}")
        if mark != "keep":
            plan.append((p, label, conf, votes))
    return plan


def apply_plan(plan) -> None:
    for path, label, conf, _ in plan:
        dest_dir = VIDEOS / label
        dest_dir.mkdir(exist_ok=True)
        dest = dest_dir / path.name
        if dest.exists():
            print(f"  SKIP (exists): {dest}")
            continue
        path.rename(dest)
        print(f"  moved {path.parent.name}\\{path.name} -> {label}\\ ({conf:.0%})")


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"

    if cmd == "scan":
        ref = build_reference(force="--force" in sys.argv)
        for k, v in ref.items():
            print(f"  {k:<34} {len(v)} reference frames")
        return 0

    if cmd == "verify":
        ref = build_reference()
        p = Path(sys.argv[2])
        label, conf, votes = classify(p, ref, frames=60)
        print(f"{p}\n  label={label} confidence={conf:.0%}")
        for k, v in sorted(votes.items(), key=lambda kv: -kv[1]):
            print(f"    {k:<34} {v}")
        return 0

    ref = build_reference()
    if not ref:
        print("No reference folders found.")
        return 1
    plan = make_plan(ref)

    if not plan:
        print("\nNothing to move.")
        return 0

    print(f"\n{len(plan)} file(s) would move:")
    for path, label, conf, _ in plan:
        print(f"  {path.parent.name}\\{path.name}  ->  {label}  ({conf:.0%})")

    if cmd == "apply":
        print("\nApplying...")
        apply_plan(plan)
    else:
        print("\nDry run. Re-run with `apply` to move them.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

