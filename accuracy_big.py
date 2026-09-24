"""Accuracy restricted to classes that have enough videos to be learnable.

Leave-one-video-out is structurally unfair to single-video classes: holding out
the only example removes the class entirely, so it can never be predicted. This
reports accuracy over classes with >= MIN_VIDEOS examples, which is the regime
the sorter actually operates in.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from search_features import FRAMES, LABELS, VIDEOS, f_combo

MIN_VIDEOS = 3

counts = {lab: len(np.unique(VIDEOS[LABELS == lab])) for lab in np.unique(LABELS)}
big = {lab for lab, n in counts.items() if n >= MIN_VIDEOS}
print("class sizes:")
for lab, n in sorted(counts.items(), key=lambda kv: -kv[1]):
    print(f"  {lab:<34} {n:3} videos{'' if lab in big else '   (too few, excluded)'}")

feat = f_combo(FRAMES)
for min_conf in (0.0, 0.4, 0.5, 0.6, 0.7):
    total = correct = wrong = abstain = 0
    for v in np.unique(VIDEOS):
        hm = VIDEOS == v
        true_label = LABELS[hm][0]
        if true_label not in big:
            continue
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

        total += 1
        pred = max(votes, key=votes.get)
        conf = votes[pred] / len(held)
        if conf < min_conf:
            abstain += 1
        elif pred == true_label:
            correct += 1
        else:
            wrong += 1
    decided = correct + wrong
    prec = correct / decided if decided else 0.0
    print(f"\nmin_conf={min_conf:.1f}: {correct}/{total} correct ({correct/total:.0%}), "
          f"{wrong} wrong, {abstain} abstain, precision-when-decided={prec:.0%}")
