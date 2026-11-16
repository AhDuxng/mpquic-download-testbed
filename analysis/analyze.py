#!/usr/bin/env python3
"""
File        : analysis/analyze.py
Project     : mpquic-download-testbed
Description : Summarises and compares runs.csv files produced by
              client/mpquic/run_experiment.py and client/mptcp/run_experiment.py.

Usage       : python3 analysis/analyze.py <runs.csv> [<runs.csv> ...] [--plot]
Example     : python3 analysis/analyze.py results/mpquic/<stamp>/runs.csv \\
                                          results/mptcp/<stamp>/runs.csv --plot

Per protocol and file
              ok/n       successful downloads (SHA-256 verified) / all runs
              mp/ok      successful runs in which multipath was really used
                         (column mp_active, defined by each runner)
              goodput    median, P25, P75, P95, mean and standard deviation
                         (Mbit/s, successful runs only)
              t_med      median download duration in seconds (handshake
                         included, same definition for both protocols)
              cpu%       median client CPU utilisation (one core = 100)
Per path      MPQUIC: byte share, smoothed RTT and losses per QUIC path
              (MPSTAT); both protocols: share of bytes received per
              interface (rx_share_<if>, includes background traffic).
Comparison    When both protocols are present: per file, the ratio of median
              goodputs MPTCP / MPQUIC. The runs are not paired (separate
              experiments), so the ratio is descriptive only; run the two
              experiments back to back under the same conditions.

Warnings    : client CPU median above 85 % (likely CPU-bound, not
              network-bound) and groups with fewer than 10 runs.
Notes       : Failed runs are never dropped: ok/n shows how many runs the
              statistics are based on. Only the standard library is used;
              --plot additionally needs matplotlib and writes
              goodput_boxplot.png next to the first CSV.
"""
import csv
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

MAX_PATHS = 3
PROTO_ORDER = {"mpquic": 0, "mptcp": 1}


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


def proto_of(r):
    if r.get("proto"):
        return r["proto"]
    return "mpquic" if "p0_bytes" in r else "unknown"


def main():
    paths = [Path(a) for a in sys.argv[1:] if not a.startswith("--")]
    if not paths:
        sys.exit(__doc__)
    rows = []
    for p in paths:
        with open(p, newline="") as f:
            rows += list(csv.DictReader(f))
    if not rows:
        sys.exit("empty CSV")

    groups = defaultdict(list)
    for r in rows:
        groups[(proto_of(r), r["file"])].append(r)
    sizes = defaultdict(int)
    for r in rows:
        sizes[r["file"]] = max(sizes[r["file"]], int(r.get("file_bytes") or 0))
    files = sorted({f for _, f in groups}, key=lambda f: sizes[f])
    protos = sorted({p for p, _ in groups}, key=lambda p: PROTO_ORDER.get(p, 9))
    labels = sorted({r.get("label", "") for r in rows} - {""})

    print(f"{len(rows)} runs, protocols: {', '.join(protos)}" + (f", label: {'; '.join(labels)}" if labels else ""))
    print("Goodput in Mbit/s (file bytes / download duration incl. handshake)\n")
    hdr = (f"{'file':16s} {'proto':7s} {'ok/n':>7s} {'mp/ok':>7s} {'med':>8s} {'p25':>8s} {'p75':>8s} "
           f"{'p95':>8s} {'mean':>8s} {'sd':>7s} {'t_med(s)':>9s} {'cpu%':>5s}")
    print(hdr)
    print("-" * len(hdr))

    cpu_bound, medians = [], {}
    for f in files:
        for p in protos:
            g = groups.get((p, f), [])
            if not g:
                continue
            ok = [r for r in g if r["ok"] == "1"]
            mp_ok = [r for r in ok if str(r.get("mp_active")) in ("1", "True")]
            gp = col(ok, "goodput_mbps")
            cpu_med = pct(col(ok, "cpu_pct"), .5)
            if col(ok, "cpu_pct") and cpu_med > 85:
                cpu_bound.append((p, f, cpu_med))
            medians[(p, f)] = pct(gp, .5)
            sd = st.stdev(gp) if len(gp) > 1 else float("nan")
            print(f"{f:16s} {p:7s} {len(ok):>3d}/{len(g):<3d} {len(mp_ok):>3d}/{len(ok):<3d} "
                  f"{pct(gp, .5):8.2f} {pct(gp, .25):8.2f} {pct(gp, .75):8.2f} {pct(gp, .95):8.2f} "
                  f"{(st.mean(gp) if gp else float('nan')):8.2f} {sd:7.2f} "
                  f"{pct(col(ok, 'duration_s'), .5):9.3f} {cpu_med:5.0f}")
        print()

    if "mpquic" in protos:
        print("MPQUIC per path, successful runs (median):")
        print(f"  {'file':16s} {'path':4s} {'share':>6s} {'srtt_ms':>8s} {'rtt_min':>8s} {'losses':>7s}  local")
        for f in files:
            ok = [r for r in groups.get(("mpquic", f), []) if r["ok"] == "1"]
            for i in range(MAX_PATHS):
                share = col(ok, f"p{i}_share")
                if not share:
                    continue
                locs = sorted({r[f"p{i}_local"].rsplit(":", 1)[0] for r in ok if r.get(f"p{i}_local")})
                print(f"  {f:16s} p{i:<3d} {st.median(share):6.2f} {pct(col(ok, f'p{i}_srtt_ms'), .5):8.1f} "
                      f"{pct(col(ok, f'p{i}_rtt_min_ms'), .5):8.1f} {pct(col(ok, f'p{i}_losses'), .5):7.0f}  "
                      f"{', '.join(locs)}")
        print()

    if "mptcp" in protos:
        print("MPTCP, successful runs (median):")
        print(f"  {'file':16s} {'subflows':>8s} {'fallback':>8s} {'t_conn':>7s} {'t_tls':>7s} {'ttfb':>7s}")
        for f in files:
            ok = [r for r in groups.get(("mptcp", f), []) if r["ok"] == "1"]
            if ok:
                print(f"  {f:16s} {pct(col(ok, 'nb_paths'), .5):8.0f} "
                      f"{sum(1 for r in ok if r.get('mptcp_fallback') == '1'):>4d}/{len(ok):<3d} "
                      f"{pct(col(ok, 't_connect_s'), .5):7.3f} {pct(col(ok, 't_tls_s'), .5):7.3f} "
                      f"{pct(col(ok, 't_first_byte_s'), .5):7.3f}")
        print()

    rx_ifaces = sorted({k[len("rx_share_"):] for r in rows for k in r if k.startswith("rx_share_")})
    if rx_ifaces:
        print("Received-byte share per interface, successful runs (median):")
        print(f"  {'file':16s} {'proto':7s} " + " ".join(f"{i:>9s}" for i in rx_ifaces))
        for f in files:
            for p in protos:
                ok = [r for r in groups.get((p, f), []) if r["ok"] == "1"]
                if ok:
                    vals = [pct(col(ok, f"rx_share_{i}"), .5) for i in rx_ifaces]
                    print(f"  {f:16s} {p:7s} " + " ".join(f"{v:9.2f}" for v in vals))
        print()

    if "mpquic" in protos and "mptcp" in protos:
        print("Comparison, median goodput MPTCP / MPQUIC (unpaired, descriptive):")
        for f in files:
            q, t = medians.get(("mpquic", f)), medians.get(("mptcp", f))
            if q and t and q == q and t == t:
                print(f"  {f:16s} MPQUIC {q:8.2f}  MPTCP {t:8.2f}  ratio {t / q:6.3f}")
        print()

    if cpu_bound:
        print("WARNING: client CPU median > 85 % (one core) for: " +
              ", ".join(f"{p}/{f} ({c:.0f}%)" for p, f, c in cpu_bound) +
              "\n  The client may be CPU-bound rather than network-bound."
              "\n  Check CLIENT_CIPHER=20 (ChaCha20), cooling, and `vcgencmd get_throttled`.")
    n_min = min(len(v) for v in groups.values())
    if n_min < 10:
        print(f"Note: only {n_min} run(s) in the smallest group; treat medians as indicative.")

    if "--plot" in sys.argv:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        keys = [(p, f) for f in files for p in protos if (p, f) in groups]
        fig, ax = plt.subplots(figsize=(1.4 * len(keys) + 2, 4.5))
        data = [col([r for r in groups[k] if r["ok"] == "1"], "goodput_mbps") for k in keys]
        ax.boxplot(data, showfliers=True)
        ax.set_xticks(range(1, len(keys) + 1),
                      [f"{f.replace('file_', '').replace('.bin', '')}\n{p}" for p, f in keys])
        ax.set_ylabel("Goodput (Mbit/s)")
        ax.set_title("Download goodput: MPQUIC vs MPTCP")
        ax.grid(axis="y", alpha=.3)
        fig.tight_layout()
        out = paths[0].with_name("goodput_boxplot.png")
        fig.savefig(out, dpi=150)
        print(f"\nPlot: {out}")


if __name__ == "__main__":
    main()
