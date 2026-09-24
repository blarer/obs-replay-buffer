"""Search feature representations for the clip classifier against cached thumbs.

Runs leave-one-video-out for each candidate feature. Frames are pre-cached, so
the whole sweep takes seconds and the comparison is apples-to-apples.
"""
import sys
from pathlib import Path

import numpy as np

D = np.load(Path(__file__).with_name("_thumbs.npz"), allow_pickle=True)
FRAMES = D["frames"].astype(np.float32) / 255.0    # (N, 36, 64, 3)
LABELS = D["labels"]
VIDEOS = D["video_ids"]


def norm(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-8)


# ------------------------------------------------------------- candidates ---

def f_color(a, g=8):
    h, w = a.shape[1] // g, a.shape[2] // g
    c = a[:, :h * g, :w * g].reshape(len(a), g, h, g, w, 3).mean(axis=(2, 4))
    return norm(c.reshape(len(a), -1))


def f_hsv_hist(a, bins=16):
    """Hue/saturation histogram: robust to layout and camera motion."""
    mx = a.max(axis=3); mn = a.min(axis=3); d = mx - mn + 1e-8
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    h = np.where(mx == r, (g - b) / d % 6,
        np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) / 6.0
    s = d / (mx + 1e-8)
    out = []
    for i in range(len(a)):
        hh, _ = np.histogram(h[i], bins=bins, range=(0, 1), weights=s[i])
        ss, _ = np.histogram(s[i], bins=bins, range=(0, 1))
        vv, _ = np.histogram(mx[i], bins=bins, range=(0, 1))
        out.append(np.concatenate([hh / hh.sum(), ss / ss.sum(), vv / vv.sum()]))
    return norm(np.array(out, dtype=np.float32))


def f_gray_grad(a, g=8):
    """Edge-orientation energy per cell: captures scene structure, not palette."""
    gray = a.mean(axis=3)
    gx = np.diff(gray, axis=2, prepend=gray[:, :, :1])
    gy = np.diff(gray, axis=1, prepend=gray[:, :1, :])
    mag = np.hypot(gx, gy)
    h, w = mag.shape[1] // g, mag.shape[2] // g
    c = mag[:, :h * g, :w * g].reshape(len(a), g, h, g, w).mean(axis=(2, 4))
    return norm(c.reshape(len(a), -1))


def f_combo(a):
    return norm(np.concatenate([f_hsv_hist(a), f_gray_grad(a) * 0.7], axis=1))


def f_combo3(a):
    return norm(np.concatenate([f_hsv_hist(a), f_gray_grad(a) * 0.7,
                                f_color(a) * 0.5], axis=1))


CANDIDATES = {
    "color8 (current)": f_color,
    "hsv_hist": f_hsv_hist,
    "gray_grad": f_gray_grad,
    "hsv+grad": f_combo,
    "hsv+grad+color": f_combo3,
}


# -------------------------------------------------------------- evaluation ---

def evaluate(feat, k=3, min_conf=0.0):
    """Leave-one-video-out accuracy using mean-of-k-nearest per label."""
    vids = np.unique(VIDEOS)
    total = correct = wrong = abstain = 0
    for v in vids:
        held_mask = VIDEOS == v
        true_label = LABELS[held_mask][0]
        held = feat[held_mask]
        ref_mask = ~held_mask

        labs = np.unique(LABELS[ref_mask])
        if len(labs) < 2:
            continue

        votes = {}
        for s in held:
            best, bd = None, 1e9
            for lab in labs:
                arr = feat[ref_mask & (LABELS == lab)]
                d = np.linalg.norm(arr - s, axis=1)
                kk = min(k, len(d))
                dist = float(np.mean(np.partition(d, kk - 1)[:kk]))
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
    return total, correct, wrong, abstain


if __name__ == "__main__":
    print(f"{'feature':>18} {'k':>3} {'min_c':>6} {'corr':>5} {'wrong':>6} "
          f"{'abst':>5}  {'acc':>5}")
    for name, fn in CANDIDATES.items():
        feat = fn(FRAMES)
        for k in (1, 3, 5):
            for mc in (0.0, 0.4, 0.5, 0.6):
                t, c, w, a = evaluate(feat, k, mc)
                print(f"{name:>18} {k:>3} {mc:6.2f} {c:5} {w:6} {a:5}  {c/t:5.0%}")
