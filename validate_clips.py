"""Leave-one-video-out validation for the clip classifier.

Each reference video is classified using a reference set built from all the
*other* videos, so a clip is never matched against frames from itself. This is
the honest measure of whether the fingerprint generalizes across sessions
(different maps, times of day, HUD states) rather than memorizing one recording.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc


def main() -> int:
    # Per-video signatures, so we can hold one out at a time.
    per_video: dict[str, list[np.ndarray]] = {}
    for folder in sc.REFERENCE_FOLDERS:
        vids = sc.videos_in(folder)
        if not vids:
            continue
        sigs = [sc.video_signatures(p, sc.REF_FRAMES) for p in vids]
        per_video[folder] = [s for s in sigs if len(s)]
        print(f"  {folder:<34} {len(per_video[folder])} videos", flush=True)

    print("\nLeave-one-video-out results:\n")
    total = correct = 0
    confusion: dict[tuple[str, str], int] = {}

    for true_label, videos in per_video.items():
        for i, held in enumerate(videos):
            # Reference set excluding the held-out video.
            ref = {}
            for lab, vs in per_video.items():
                keep = [v for j, v in enumerate(vs) if not (lab == true_label and j == i)]
                if keep:
                    ref[lab] = np.vstack(keep)
            if len(ref) < 2:
                continue

            votes: dict[str, int] = {}
            for s in held:
                best, best_d = None, 1e9
                for lab, arr in ref.items():
                    d = float(np.min(np.linalg.norm(arr - s, axis=1)))
                    if d < best_d:
                        best, best_d = lab, d
                key = best if best_d <= sc.MAX_DISTANCE else "unknown"
                votes[key] = votes.get(key, 0) + 1

            decided = {k: v for k, v in votes.items() if k != "unknown"}
            pred = max(decided, key=decided.get) if decided else "unknown"
            conf = (decided[pred] / len(held)) if decided else 0.0

            total += 1
            ok = pred == true_label
            correct += ok
            confusion[(true_label, pred)] = confusion.get((true_label, pred), 0) + 1
            if not ok:
                print(f"  MISS  {true_label:<32} -> {pred:<32} {conf:5.0%}")

    print(f"\naccuracy: {correct}/{total} = {correct/total:.0%}")

    print("\nconfusion (true -> predicted):")
    for (t, p), c in sorted(confusion.items(), key=lambda kv: -kv[1]):
        flag = "" if t == p else "   <-- error"
        print(f"  {t:<32} -> {p:<32} {c}{flag}")

    return 0 if correct / total >= 0.8 else 1


if __name__ == "__main__":
    raise SystemExit(main())
