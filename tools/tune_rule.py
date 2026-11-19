"""Compare decision rules for the clip classifier using cached signatures.

The single-nearest-neighbour rule is brittle: one lucky frame match can carry a
whole video. These variants test more robust per-frame scoring (k-NN, margin
requirements) without re-extracting frames.
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc

SIGCACHE = Path(__file__).with_name("_sweep-sigs.json")
raw = json.loads(SIGCACHE.read_text())
PER_VIDEO = {k: [np.array(v, dtype=np.float32) for v in vs] for k, vs in raw.items()}


def frame_scores(ref, s, k):
    """Distance from frame s to each label, as the mean of its k nearest frames."""
    out = {}
    for lab, arr in ref.items():
        d = np.linalg.norm(arr - s, axis=1)
        kk = min(k, len(d))
        out[lab] = float(np.mean(np.partition(d, kk - 1)[:kk]))
    return out


def evaluate(rule, k, max_dist, min_conf, margin=0.0):
    total = correct = wrong = abstain = 0
    for true_label, videos in PER_VIDEO.items():
        for i, held in enumerate(videos):
            ref = {}
            for lab, vs in PER_VIDEO.items():
                keep = [v for j, v in enumerate(vs) if not (lab == true_label and j == i)]
                if keep:
                    ref[lab] = np.vstack(keep)
            if len(ref) < 2:
                continue

            if rule == "vote":
                votes = {}
                for s in held:
                    sc_ = frame_scores(ref, s, k)
                    order = sorted(sc_.items(), key=lambda kv: kv[1])
                    best, bd = order[0]
                    second = order[1][1] if len(order) > 1 else 1e9
                    # Require the winner to be clearly closer than the runner-up.
                    if bd <= max_dist and (second - bd) >= margin:
                        votes[best] = votes.get(best, 0) + 1
                decided = votes
            else:  # "pool": aggregate distances across all frames, then pick once
                acc = {lab: [] for lab in ref}
                for s in held:
                    for lab, d in frame_scores(ref, s, k).items():
                        acc[lab].append(d)
                # Use the best 25% of frames per label: a clip contains menus and
                # loading screens that match nothing, and those should not drown
                # out the frames that do identify the game.
                agg = {}
                for lab, ds in acc.items():
                    ds = np.sort(np.array(ds))
                    top = ds[:max(1, len(ds) // 4)]
                    agg[lab] = float(np.mean(top))
                order = sorted(agg.items(), key=lambda kv: kv[1])
                best, bd = order[0]
                second = order[1][1] if len(order) > 1 else 1e9
                decided = {best: 1} if (bd <= max_dist and (second - bd) >= margin) else {}

            total += 1
            if not decided:
                abstain += 1
                continue
            pred = max(decided, key=decided.get)
            conf = decided[pred] / (len(held) if rule == "vote" else 1)
            if rule == "vote" and conf < min_conf:
                abstain += 1
            elif pred == true_label:
                correct += 1
            else:
                wrong += 1
    return total, correct, wrong, abstain


print(f"{'rule':>6} {'k':>3} {'max_d':>6} {'min_c':>6} {'margin':>7} "
      f"{'corr':>5} {'wrong':>6} {'abst':>5}  {'acc':>5}")
results = []
for rule in ("vote", "pool"):
    for k in (1, 3, 5):
        for max_dist in (0.4, 0.5, 0.6, 0.8, 1.5):
            for min_conf in ((0.2, 0.3, 0.4) if rule == "vote" else (0.0,)):
                for margin in (0.0, 0.02, 0.05):
                    t, c, w, a = evaluate(rule, k, max_dist, min_conf, margin)
                    results.append((c, w, a, rule, k, max_dist, min_conf, margin, t))

# Show the best few by (fewest wrong, most correct).
results.sort(key=lambda r: (r[1], -r[0]))
for c, w, a, rule, k, md, mc, mg, t in results[:25]:
    print(f"{rule:>6} {k:>3} {md:6.2f} {mc:6.2f} {mg:7.3f} {c:5} {w:6} {a:5}  {c/t:5.0%}")
