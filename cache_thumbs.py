"""Cache reference thumbnails to disk so feature engineering does not re-decode.

Frame extraction dominates runtime (~4.5s/video); feature evaluation is
milliseconds. Caching raw thumbnails once makes the feature search a fast loop.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc

OUT = Path(__file__).with_name("_thumbs.npz")
N = 24   # frames per video, more than REF_FRAMES so features can subsample


def main() -> int:
    arrays, labels, video_ids = [], [], []
    vid = 0
    for folder in sc.REFERENCE_FOLDERS:
        for p in sc.videos_in(folder):
            frames = sc.grab_frames(p, N)
            if not frames:
                continue
            for f in frames:
                arrays.append(np.asarray(f.resize((64, 36)), dtype=np.uint8))
                labels.append(folder)
                video_ids.append(vid)
            print(f"  {folder:<34} {p.name:<40} {len(frames)} frames", flush=True)
            vid += 1

    np.savez_compressed(OUT,
                        frames=np.stack(arrays),
                        labels=np.array(labels),
                        video_ids=np.array(video_ids))
    print(f"\nsaved {len(arrays)} thumbnails from {vid} videos -> {OUT.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
