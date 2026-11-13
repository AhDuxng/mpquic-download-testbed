#!/usr/bin/env python3
"""Summarise runs.csv from client/run_experiment.py.

  python3 analysis/analyze.py results/<stamp>/runs.csv [--plot]

Per (file, mode): runs, success rate, goodput median / P25 / P75 / P95 / mean±sd,
median completion time, median byte share of each path, and the median ratio of
multipath to single-path goodput (paired by repetition).
Goodput statistics use only successful runs; the success column shows how many
runs that is, so a mode that fails often cannot look good by hiding failures.
Uses only the standard library; --plot needs matplotlib.
"""
import csv
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path


def pct(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    i = (len(xs) - 1) * q
    lo, hi = int(i), min(int(i) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    rows = list(csv.DictReader(open(path)))
    if not rows:
        sys.exit("empty CSV")

    groups = defaultdict(list)
    for r in rows:
        groups[(r["file"], r["mode"])].append(r)

    def fsize(name):
        return max((int(r["file_bytes"] or 0) for r in rows if r["file"] == name), default=0)

    files = sorted({k[0] for k in groups}, key=fsize)
    modes = sorted({k[1] for k in groups}, key=lambda m: {"sp": 0, "mp-sim": 1, "mp": 2}.get(m, 9))

    hdr = (f"{'file':16s} {'mode':7s} {'ok/n':>7s} {'med':>8s} {'p25':>8s} {'p75':>8s} {'p95':>8s} "
           f"{'mean':>8s} {'sd':>7s} {'t_med(s)':>9s} {'cpu%':>5s}  path shares (median)")
    print("Goodput in Mbit/s (file bytes / connection duration incl. handshake)\n")
    print(hdr)
    print("-" * len(hdr))
    cpu_bound = []
    for f in files:
        for m in modes:
            g = groups.get((f, m), [])
            if not g:
                continue
            ok = [r for r in g if r["ok"] == "1"]
            gp = [fnum(r["goodput_mbps"]) for r in ok if fnum(r["goodput_mbps"])]
            du = [fnum(r["duration_s"]) for r in ok if fnum(r["duration_s"])]
            cp = [fnum(r.get("cpu_pct")) for r in ok if fnum(r.get("cpu_pct")) is not None]
            cpu_med = pct(cp, .5)
            if cp and cpu_med > 85:
                cpu_bound.append((f, m, cpu_med))
            shares = []
            for i in range(3):
                s = [fnum(r.get(f"p{i}_share")) for r in ok if fnum(r.get(f"p{i}_share")) is not None]
                if s:
                    shares.append(f"p{i}={st.median(s):.2f}")
            sd = st.stdev(gp) if len(gp) > 1 else float("nan")
            print(f"{f:16s} {m:7s} {len(ok):>3d}/{len(g):<3d} "
                  f"{pct(gp, .5):8.2f} {pct(gp, .25):8.2f} {pct(gp, .75):8.2f} {pct(gp, .95):8.2f} "
                  f"{(st.mean(gp) if gp else float('nan')):8.2f} {sd:7.2f} {pct(du, .5):9.3f} {cpu_med:5.0f}  {' '.join(shares)}")
        print()

    # Paired comparison against single path (same rep, same file)
    if "sp" in modes:
        print("Paired ratio goodput(mode)/goodput(sp), same file and repetition:")
        for f in files:
            sp = {r["rep"]: fnum(r["goodput_mbps"]) for r in groups.get((f, "sp"), []) if r["ok"] == "1"}
            for m in modes:
                if m == "sp":
                    continue
                ratios = [fnum(r["goodput_mbps"]) / sp[r["rep"]]
                          for r in groups.get((f, m), [])
                          if r["ok"] == "1" and sp.get(r["rep"]) and fnum(r["goodput_mbps"])]
                if ratios:
                    wins = sum(1 for x in ratios if x > 1)
                    print(f"  {f:16s} {m:7s} n={len(ratios):3d} median={st.median(ratios):.3f} "
                          f"P25={pct(ratios, .25):.3f} P75={pct(ratios, .75):.3f} faster_in={wins}/{len(ratios)}")
    if cpu_bound:
        print("\nWARNING: client CPU median > 85 % (one core) in: " +
              ", ".join(f"{f}/{m} ({c:.0f}%)" for f, m, c in cpu_bound) +
              "\n  The client may be CPU-bound, not network-bound; a multipath gain can be hidden."
              "\n  Check CLIENT_CIPHER=20 (ChaCha20), cooling, and `vcgencmd get_throttled`.")
    n_min = min(len(v) for v in groups.values())
    if n_min < 10:
        print(f"\nNote: only {n_min} run(s) in the smallest group; treat medians as indicative.")

    if "--plot" in sys.argv:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(1.8 * len(files) * len(modes) + 2, 4.5))
        data, labels = [], []
        for f in files:
            for m in modes:
                data.append([fnum(r["goodput_mbps"]) for r in groups.get((f, m), [])
                             if r["ok"] == "1" and fnum(r["goodput_mbps"])])
                labels.append(f"{f.replace('file_', '').replace('.bin', '')}\n{m}")
        ax.boxplot(data, showfliers=True)
        ax.set_xticks(range(1, len(labels) + 1), labels)
        ax.set_ylabel("Goodput (Mbit/s)")
        ax.set_title("Download goodput: single path vs multipath QUIC")
        ax.grid(axis="y", alpha=.3)
        fig.tight_layout()
        out = path.with_name("goodput_boxplot.png")
        fig.savefig(out, dpi=150)
        print(f"\nPlot: {out}")


if __name__ == "__main__":
    main()
