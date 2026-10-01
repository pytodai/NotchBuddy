#!/usr/bin/env python3
"""Finds the jerks in a rendered film: cuts and pops (one frame jumps), and camera or speed changes without easing.

    scripts/promo/motion-check.py VIDEO [--allow-cuts 8.1,11.2,…] [--allow-ui 16.8,…] [--tolerance 0.03] [--csv diff.csv]
                                  [--all]

The video is decoded at 320×180 gray (ffmpeg pipe). For every frame: the mean absolute difference from the frame before
(0…255 gray levels), normalized to "per 1/60 s" so 60 and 120 fps renders read alike. Two kinds of trouble:

  SPIKES          a single frame that jumps much more than its neighbours (a hard cut, a punch-in, a content pop in a
                  close shot). Spikes at the --allow-cuts times (± --tolerance s) are intended cuts.
  VELOCITY STEPS  the level of motion changes within 2–3 frames and stays changed (a camera move that starts or stops
                  without easing, a speed-ramp kink, a sudden pan): the diff curve steps instead of ramping.

Dissolves and dips that are eased show as neither. The island's own transitions (a close, a page swap) start on a
spring at full speed, as in the app: a step that begins at one of the --allow-ui times (the storyboard's beats, up to
0.25 s after) is the product's motion at 1x, reported but not counted. Exit status: 0 when only intended cuts spike and
nothing else steps.
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np

W, H = 320, 180


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate",
         "-show_entries", "format=duration", "-of", "json", path],
        check=True, capture_output=True, text=True).stdout
    info = json.loads(out)
    stream = info["streams"][0]
    num, den = stream["r_frame_rate"].split("/")
    return stream["width"], stream["height"], float(num) / float(den), float(info["format"]["duration"])


def frames(path):
    """Yields 320×180 gray frames as int16 arrays."""
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-vf", f"scale={W}:{H}:flags=area,format=gray",
           "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    size = W * H
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=size * 8) as proc:
        while True:
            buf = proc.stdout.read(size)
            if len(buf) < size:
                break
            yield np.frombuffer(buf, dtype=np.uint8).reshape(H, W).astype(np.int16)


def diffs(path):
    prev = None
    out = []
    for f in frames(path):
        if prev is not None:
            out.append(float(np.abs(f - prev).mean()))
        prev = f
    # d[i]: frame i against frame i - 1 (d[0] = 0).
    return np.array([0.0] + out)


def local_median(d, i, k, skip=0):
    """Median of d around i (k frames each side), leaving out i and `skip` frames next to it."""
    lo, hi = max(0, i - k - skip), min(len(d), i + k + skip + 1)
    idx = [j for j in range(lo, hi) if abs(j - i) > skip]
    return float(np.median(d[idx])) if idx else 0.0


def find_spikes(d, fps, ratio, jump, floor):
    k = max(3, round(0.05 * fps))
    spikes = []
    for i in range(1, len(d)):
        base = local_median(d, i, k)
        if d[i] >= ratio * max(base, floor) and d[i] - base >= jump:
            spikes.append((i, d[i], base))
    # One event per jump (a pop can take two frames): keep the strongest within 0.05 s.
    merged = []
    for s in spikes:
        if merged and s[0] - merged[-1][0] <= max(2, round(0.05 * fps)):
            if s[1] > merged[-1][1]:
                merged[-1] = s
        else:
            merged.append(s)
    return merged


def find_steps(u, fps, spike_frames, ratio, step_min, floor):
    """u: motion per 1/60 s. A step: the mean over the next w frames differs from the mean over the previous w frames by
    at least `step_min` and by a factor of `ratio`, and the change is not spread over the wider neighbourhood (a ramp)."""
    w = max(2, round(0.04 * fps))
    clean = u.copy()
    # Cuts are reported as spikes; for the motion level they are replaced by their neighbourhood.
    for i in spike_frames:
        lo, hi = max(1, i - 2 * w), min(len(u), i + 2 * w + 1)
        clean[i] = np.median(np.delete(u[lo:hi], i - lo))
    steps = []
    for i in range(w + 1, len(u) - w):
        if any(abs(i - s) <= w for s in spike_frames):
            continue
        before = clean[i - w:i].mean()
        after = clean[i:i + w].mean()
        lo, hi = min(before, after), max(before, after)
        if hi - lo < step_min or (hi + floor) / (lo + floor) < ratio:
            continue
        # A ramp spreads its change: the level w frames further on each side keeps moving the same way. A step does not:
        # most of the change happens across i itself.
        far_before = clean[max(1, i - 3 * w):i - w].mean() if i - w > 1 else before
        far_after = clean[i + w:min(len(u), i + 3 * w)].mean() if i + w < len(u) else after
        total = abs(far_after - far_before) + 1e-6
        share = (hi - lo) / max(total, hi - lo)
        if share < 0.6:
            continue
        steps.append((i, before, after, share))
    merged = []
    for s in steps:
        if merged and s[0] - merged[-1][0] <= max(3, round(0.12 * fps)):
            if abs(s[2] - s[1]) > abs(merged[-1][2] - merged[-1][1]):
                merged[-1] = s
        else:
            merged.append(s)
    return merged


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("video")
    p.add_argument("--allow-cuts", default="", help="intended cut times in seconds, comma-separated")
    p.add_argument("--allow-ui", default="",
                   help="video times of the island's own transitions (closes, page swaps), comma-separated")
    p.add_argument("--tolerance", type=float, default=0.03, help="seconds around an intended cut (default 0.03)")
    p.add_argument("--spike-ratio", type=float, default=4.0, help="a spike is this many times its neighbours (4)")
    p.add_argument("--spike-jump", type=float, default=1.5, help="…and at least this many gray levels above them (1.5)")
    p.add_argument("--step-ratio", type=float, default=2.5, help="a velocity step changes the motion level ×this (2.5)")
    p.add_argument("--step-min", type=float, default=0.8, help="…by at least this many gray levels per 1/60 s (0.8)")
    p.add_argument("--csv", help="write time, diff, motion per 1/60 s to this file")
    p.add_argument("--all", action="store_true", help="also print the motion level every 0.5 s")
    a = p.parse_args()

    try:
        os.nice(10)
    except OSError:
        pass
    width, height, fps, duration = probe(a.video)
    d = diffs(a.video)
    n = len(d)
    u = d * fps / 60.0
    floor = max(0.15, float(np.percentile(d[1:], 10)) if n > 1 else 0.15)
    allowed = [float(x) for x in a.allow_cuts.split(",") if x.strip()]
    ui = [float(x) for x in a.allow_ui.split(",") if x.strip()]

    spikes = find_spikes(d, fps, a.spike_ratio, a.spike_jump, floor)
    steps = find_steps(u, fps, [s[0] for s in spikes], a.step_ratio, a.step_min, floor * fps / 60)

    print(f"motion-check: {a.video}")
    print(f"  {width}x{height} @ {fps:g} fps, {n} frames, {duration:.2f} s; analysed at {W}x{H} gray")
    print(f"  noise floor {floor:.2f}, median motion {np.median(u[1:]):.2f}, p95 {np.percentile(u[1:], 95):.2f} "
          f"(gray levels per 1/60 s)")
    unexpected = 0
    used = set()
    print(f"SPIKES (one-frame jumps ≥ ×{a.spike_ratio:g} their neighbours): {len(spikes)}")
    for i, value, base in spikes:
        t = i / fps
        match = next((c for c in allowed if abs(c - t) <= a.tolerance + 0.5 / fps), None)
        if match is not None:
            used.add(match)
            tag = f"cut ✓ (allowed {match:g})"
        else:
            tag = "UNEXPECTED"
            unexpected += 1
        print(f"  {t:8.3f} s  frame {i:5d}  diff {value:6.2f}  baseline {base:5.2f}  ×{value / max(base, floor):5.1f}  {tag}")
    missing = [c for c in allowed if c not in used]
    if missing:
        print(f"  (no spike at allowed cut(s): {', '.join(f'{c:g}' for c in missing)} — dissolved, or a still cut)")
    print(f"VELOCITY STEPS (motion level changes ×{a.step_ratio:g} within ~{max(2, round(0.04 * fps))} frames): {len(steps)}")
    unexplained = 0
    for i, before, after, share in steps:
        kind = "starts" if after > before else "stops"
        t = i / fps
        beat = next((u for u in ui if -0.05 <= t - u <= 0.25), None)
        if beat is not None:
            tag = f"island transition ✓ (allowed {beat:g})"
        else:
            tag = "UNEXPECTED"
            unexplained += 1
        print(f"  {t:8.3f} s  frame {i:5d}  {before:5.2f} → {after:5.2f} per 1/60 s  (motion {kind} abruptly)  {tag}")
    if a.all:
        print("MOTION every 0.5 s (mean per 1/60 s):")
        step = max(1, round(fps / 2))
        for i in range(0, n, step):
            seg = u[i:i + step]
            bar = "#" * min(60, int(round(seg.mean() * 4)))
            print(f"  {i / fps:6.2f} s  {seg.mean():5.2f}  max {seg.max():6.2f}  {bar}")
    if a.csv:
        with open(a.csv, "w") as f:
            f.write("time,diff,motion60\n")
            for i in range(n):
                f.write(f"{i / fps:.4f},{d[i]:.4f},{u[i]:.4f}\n")
    ok = unexpected == 0 and unexplained == 0
    print(f"SUMMARY: {len(spikes) - unexpected} intended cut(s), {unexpected} unexpected spike(s), "
          f"{len(steps)} velocity step(s) ({len(steps) - unexplained} at island transitions, {unexplained} unexpected) — "
          f"{'CLEAN' if ok else 'NOT CLEAN'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
