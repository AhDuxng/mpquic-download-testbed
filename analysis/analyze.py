#!/usr/bin/env python3
"""
File        : analysis/analyze.py
Project     : mpquic-download-testbed
Description : Summarises a runs.csv produced by client/run_experiment.py.

Usage       : python3 analysis/analyze.py results/<stamp>/runs.csv [--plot]

Per file    : ok/n       successful downloads (SHA-256 verified) / all runs
              mp/ok      successful runs in which multipath was negotiated AND
                         at least two paths received data
              goodput    median, P25, P75, P95, mean and standard deviation
                         (Mbit/s, successful runs only)
              t_med      median connection duration in seconds
              cpu%       median client CPU utilisation (one core = 100)
              per path   median byte share, smoothed RTT and loss count

Warnings    : client CPU median above 85 % (likely CPU-bound, not network-bound),
              and groups with fewer than 10 runs.

Notes       : Failed runs are never dropped: ok/n shows how many runs the
              goodput statistics are based on. Only the standard library is
              used; --plot additionally needs matplotlib and writes
              goodput_boxplot.png next to the CSV.
"""
import csv
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

MAX_PATHS = 3


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


def col(rows, name):
    return [v for v in (fnum(r.get(name)) for r in rows) if v is not None]


def paths_used(r):
    return sum(1 for i in range(MAX_PATHS) if (fnum(r.get(f"p{i}_bytes")) or 0) > 0)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("empty CSV")

    groups = defaultdict(list)
    for r in rows:
        groups[r["file"]].append(r)

    def fsize(name):
        return max((int(r["file_bytes"] or 0) for r in groups[name]), default=0)

    files = sorted(groups, key=fsize)
    label = sorted({r.get("label", "") for r in rows} - {""})

    print(f"Multipath QUIC download, {len(rows)} runs" + (f", label: {', '.join(label)}" if label else ""))
    print("Goodput in Mbit/s (file bytes / connection duration incl. handshake)\n")
    hdr = (f"{'file':16s} {'ok/n':>7s} {'mp/ok':>7s} {'med':>8s} {'p25':>8s} {'p75':>8s} {'p95':>8s} "
           f"{'mean':>8s} {'sd':>7s} {'t_med(s)':>9s} {'cpu%':>5s}")
    print(hdr)
    print("-" * len(hdr))

    cpu_bound = []
    for f in files:
        g = groups[f]
        ok = [r for r in g if r["ok"] == "1"]
        mp_ok = [r for r in ok if str(r.get("mp_negotiated")) in ("1", "True") and paths_used(r) >= 2]
        gp = col(ok, "goodput_mbps")
        du = col(ok, "duration_s")
        cpu_med = pct(col(ok, "cpu_pct"), .5)
        if col(ok, "cpu_pct") and cpu_med > 85:
            cpu_bound.append((f, cpu_med))
        sd = st.stdev(gp) if len(gp) > 1 else float("nan")
        print(f"{f:16s} {len(ok):>3d}/{len(g):<3d} {len(mp_ok):>3d}/{len(ok):<3d} "
              f"{pct(gp, .5):8.2f} {pct(gp, .25):8.2f} {pct(gp, .75):8.2f} {pct(gp, .95):8.2f} "
              f"{(st.mean(gp) if gp else float('nan')):8.2f} {sd:7.2f} {pct(du, .5):9.3f} {cpu_med:5.0f}")

    print("\nPer path, successful runs (median):")
    print(f"  {'file':16s} {'path':4s} {'share':>6s} {'srtt_ms':>8s} {'rtt_min':>8s} {'losses':>7s}  local")
    for f in files:
        ok = [r for r in groups[f] if r["ok"] == "1"]
        for i in range(MAX_PATHS):
            share = col(ok, f"p{i}_share")
            if not share:
                continue
            locs = sorted({r[f"p{i}_local"].rsplit(":", 1)[0] for r in ok if r.get(f"p{i}_local")})
            print(f"  {f:16s} p{i:<3d} {st.median(share):6.2f} {pct(col(ok, f'p{i}_srtt_ms'), .5):8.1f} "
                  f"{pct(col(ok, f'p{i}_rtt_min_ms'), .5):8.1f} {pct(col(ok, f'p{i}_losses'), .5):7.0f}  "
                  f"{', '.join(locs)}")

    if cpu_bound:
        print("\nWARNING: client CPU median > 85 % (one core) for: " +
              ", ".join(f"{f} ({c:.0f}%)" for f, c in cpu_bound) +
              "\n  The client may be CPU-bound rather than network-bound."
              "\n  Check CLIENT_CIPHER=20 (ChaCha20), cooling, and `vcgencmd get_throttled`.")
    n_min = min(len(v) for v in groups.values())
    if n_min < 10:
        print(f"\nNote: only {n_min} run(s) in the smallest group; treat medians as indicative.")

    if "--plot" in sys.argv:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(1.6 * len(files) + 2, 4.5))
        data = [col([r for r in groups[f] if r["ok"] == "1"], "goodput_mbps") for f in files]
        ax.boxplot(data, showfliers=True)
        ax.set_xticks(range(1, len(files) + 1), [f.replace("file_", "").replace(".bin", "") for f in files])
        ax.set_xlabel("File size")
        ax.set_ylabel("Goodput (Mbit/s)")
        ax.set_title("Multipath QUIC download goodput")
        ax.grid(axis="y", alpha=.3)
        fig.tight_layout()
        out = path.with_name("goodput_boxplot.png")
        fig.savefig(out, dpi=150)
        print(f"\nPlot: {out}")


if __name__ == "__main__":
    main()
