"""Sweep MAX_DISTANCE / MIN_CONFIDENCE for the clip classifier.

Caches per-video signatures once, then evaluates thresholds cheaply. Reports
accuracy, wrong-label rate, and abstain rate. A wrong label misfiles a clip,
which is worse than abstaining, so the sweep favors low error over low abstain.
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc

SIGCACHE = Path(__file__).with_name("_sweep-sigs.json")


def load_sigs() -> dict[str, list[np.ndarray]]:
    if SIGCACHE.exists():
        raw = json.loads(SIGCACHE.read_text())
        return {k: [np.array(v, dtype=np.float32) for v in vs] for k, vs in raw.items()}
    per_video = {}
    for folder in sc.REFERENCE_FOLDERS:
        vids = sc.videos_in(folder)
        if not vids:
            continue
        sigs = [sc.video_signatures(p, sc.REF_FRAMES) for p in vids]
        per_video[folder] = [s for s in sigs if len(s)]
        print(f"  {folder:<34} {len(per_video[folder])} videos", flush=True)
    SIGCACHE.write_text(json.dumps(
        {k: [v.tolist() for v in vs] for k, vs in per_video.items()}))
    return per_video


def evaluate(per_video, max_dist, min_conf):
    total = correct = wrong = abstain = 0
    for true_label, videos in per_video.items():
        for i, held in enumerate(videos):
            ref = {}
            for lab, vs in per_video.items():
                keep = [v for j, v in enumerate(vs) if not (lab == true_label and j == i)]
                if keep:
                    ref[lab] = np.vstack(keep)
            if len(ref) < 2:
                continue

            votes = {}
            for s in held:
                best, best_d = None, 1e9
                for lab, arr in ref.items():
                    d = float(np.min(np.linalg.norm(arr - s, axis=1)))
                    if d < best_d:
                        best, best_d = lab, d
                key = best if best_d <= max_dist else "unknown"
                votes[key] = votes.get(key, 0) + 1

            decided = {k: v for k, v in votes.items() if k != "unknown"}
            total += 1
            if not decided:
                abstain += 1
                continue
            pred = max(decided, key=decided.get)
            conf = decided[pred] / len(held)
            if conf < min_conf:
                abstain += 1
            elif pred == true_label:
                correct += 1
            else:
                wrong += 1
    return total, correct, wrong, abstain


def main() -> int:
    per_video = load_sigs()
    print(f"\n{'max_d':>6} {'min_c':>6} {'correct':>8} {'wrong':>6} {'abstain':>8}  {'acc':>5}")
    best = None
    for max_dist in [0.22, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 1.0, 1.5]:
        for min_conf in [0.25, 0.35, 0.45, 0.55]:
            t, c, w, a = evaluate(per_video, max_dist, min_conf)
            acc = c / t
            print(f"{max_dist:6.2f} {min_conf:6.2f} {c:8} {w:6} {a:8}  {acc:5.0%}")
            # Prefer zero wrong labels, then maximize correct.
            score = (w == 0, c)
            if best is None or score > best[0]:
                best = (score, max_dist, min_conf, c, w, a, t)

    _, md, mc, c, w, a, t = best
    print(f"\nbest: MAX_DISTANCE={md} MIN_CONFIDENCE={mc}")
    print(f"      {c}/{t} correct ({c/t:.0%}), {w} wrong, {a} abstain")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
