"""Show which reference videos the chosen feature still misclassifies."""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc
from search_features import FRAMES, LABELS, VIDEOS, f_combo

# Rebuild the video -> filename map in the same order cache_thumbs.py used.
names = []
for folder in sc.REFERENCE_FOLDERS:
    for p in sc.videos_in(folder):
        names.append(f"{folder}\\{p.name}")

feat = f_combo(FRAMES)
for v in np.unique(VIDEOS):
    hm = VIDEOS == v
    true_label = LABELS[hm][0]
    held, rm = feat[hm], ~hm
    labs = np.unique(LABELS[rm])

    votes = {}
    for s in held:
        best, bd = None, 1e9
        for lab in labs:
            arr = feat[rm & (LABELS == lab)]
            d = np.linalg.norm(arr - s, axis=1)
            dist = float(np.mean(np.partition(d, 2)[:3]))
            if dist < bd:
                best, bd = lab, dist
        votes[best] = votes.get(best, 0) + 1

    pred = max(votes, key=votes.get)
    conf = votes[pred] / len(held)
    if pred != true_label:
        name = names[v] if v < len(names) else f"video {v}"
        print(f"MISS  {name}")
        print(f"      true={true_label}  pred={pred}  conf={conf:.0%}")
        print(f"      votes={dict(sorted(votes.items(), key=lambda kv: -kv[1]))}")
