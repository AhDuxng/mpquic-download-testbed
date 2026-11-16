"""
File        : client/lib/testbed.py
Project     : mpquic-download-testbed
Description : Shared measurement harness for the MPQUIC and MPTCP clients. Both
              experiment runners use the same configuration, the same file
              integrity check, the same CPU, temperature and throttling probes,
              the same per-interface byte counters, the same CSV columns for
              common metrics and the same repetition and shuffling scheme, so
              that the two protocols are measured identically.

Interfaces  : The paths under test are the interface of path 0 (PRIMARY_IF, or
              the interface of the default route) plus every interface listed
              in ALT_PATHS ("ip/ifindex,..."). Received bytes are read from
              /sys/class/net/<if>/statistics/rx_bytes before and after each
              download; the delta includes any background traffic on that
              interface, so it is a cross-check, not a substitute for
              protocol-level per-path counters.

Runner API  : run_experiment(proto, args, cfg, alt, download_fn, extra_cols, meta_extra)
              download_fn(fname, outdir, logdir, tag, timeout) must write the file to
              outdir/fname, write logdir/tag.log, and return
              (output_text, return_code, protocol_row_dict, duration_s or None).
"""
import csv
import datetime as dt
import hashlib
import os
import random
import re
import resource
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMON_COLS = ["ts", "proto", "label", "rep", "order", "file", "file_bytes", "exit_code", "ok",
               "mp_active", "nb_paths", "duration_s", "goodput_mbps", "wall_s", "cpu_s", "cpu_pct",
               "soc_temp_c"]


def load_config():
    cfg = {}
    for line in (ROOT / "config.env").read_text().splitlines():
        m = re.match(r'^\s*([A-Z_]+)="?([^"#]*)"?', line)
        if m:
            cfg[m.group(1)] = os.path.expandvars(m.group(2).strip())
    return cfg


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def soc_temp_c():
    try:
        return f"{int(Path('/sys/class/thermal/thermal_zone0/temp').read_text()) / 1000:.1f}"
    except (OSError, ValueError):
        return ""


def pi_throttled():
    try:
        return subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True,
                              timeout=5).stdout.strip().split("=")[-1]
    except (OSError, subprocess.SubprocessError):
        return ""


def alt_paths():
    alt = os.environ.get("ALT_PATHS", "").strip()
    if not alt:
        sys.exit("ALT_PATHS is required, e.g. ALT_PATHS=10.50.40.68/3 (see README, multipath setup)")
    return alt


def iface_by_index(idx):
    for d in Path("/sys/class/net").glob("*"):
        try:
            if int((d / "ifindex").read_text()) == int(idx):
                return d.name
        except (OSError, ValueError):
            continue
    return None


def default_iface():
    try:
        out = subprocess.run(["ip", "-o", "route", "show", "default"], capture_output=True,
                             text=True, timeout=5).stdout
        m = re.search(r"\bdev (\S+)", out)
        return m.group(1) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


def path_ifaces(alt):
    names = []
    primary = os.environ.get("PRIMARY_IF")
    first = iface_by_index(primary) if primary else default_iface()
    if first:
        names.append(first)
    for item in alt.split(","):
        _, _, idx = item.strip().partition("/")
        name = iface_by_index(idx) if idx.isdigit() and int(idx) > 0 else None
        if name and name not in names:
            names.append(name)
    return names


def rx_bytes(ifaces):
    out = {}
    for i in ifaces:
        try:
            out[i] = int(Path(f"/sys/class/net/{i}/statistics/rx_bytes").read_text())
        except (OSError, ValueError):
            out[i] = None
    return out


def fetch_sums(download_fn, outdir, logdir):
    _, rc, _, _ = download_fn("SHA256SUMS", outdir, logdir, "000_SHA256SUMS", 60)
    sums_path = outdir / "SHA256SUMS"
    if not sums_path.exists():
        return None, rc
    ref = {}
    for line in sums_path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            ref[parts[1].lstrip("*")] = parts[0]
    sums_path.unlink()
    return ref, rc


def common_args(ap):
    ap.add_argument("-n", "--reps", type=int, default=10, help="repetitions per file")
    ap.add_argument("-f", "--files", default=None, help="comma list; default = all TEST_FILES")
    ap.add_argument("-t", "--timeout", type=int, default=300, help="seconds per download")
    ap.add_argument("-p", "--pause", type=float, default=1.0, help="seconds between runs")
    ap.add_argument("--label", default="", help="free text stored in every row, e.g. 'eth0+wlan0'")
    ap.add_argument("--seed", type=int, default=None, help="shuffle seed (recorded)")
    ap.add_argument("--dl-dir", default=None,
                    help="where files are written before the SHA check; default CLIENT_DL_DIR "
                         "(/dev/shm = RAM) so SD-card speed does not limit the download")


def run_experiment(proto, args, cfg, alt, download_fn, extra_cols, meta_extra=""):
    files = ([f.strip() for f in args.files.split(",")] if args.files
             else [s.split(":")[0] for s in cfg["TEST_FILES"].split()])
    seed = args.seed if args.seed is not None else random.randrange(1 << 31)
    rng = random.Random(seed)
    ifaces = path_ifaces(alt)

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    resdir = ROOT / "results" / proto / stamp
    logdir = resdir / "logs"
    logdir.mkdir(parents=True)
    if args.dl_dir:
        base = Path(args.dl_dir)
    elif Path("/dev/shm").is_dir() and cfg.get("CLIENT_DL_DIR"):
        base = Path(cfg["CLIENT_DL_DIR"])
    else:
        base = resdir / "downloads"
    outdir = base / f"{proto}-{stamp}"
    outdir.mkdir(parents=True, exist_ok=True)

    ref, rc = fetch_sums(download_fn, outdir, logdir)
    if ref is None:
        shutil.rmtree(outdir, ignore_errors=True)
        sys.exit(f"Cannot fetch SHA256SUMS from server (rc={rc}). See {logdir}/000_SHA256SUMS.log")
    missing = [f for f in files if f not in ref]
    if missing:
        shutil.rmtree(outdir, ignore_errors=True)
        shutil.rmtree(resdir, ignore_errors=True)
        sys.exit(f"Not on the server (absent from SHA256SUMS): {', '.join(missing)}. "
                 f"Use -f or run server/gen_testfiles.sh.")

    meta = resdir / "meta.txt"
    meta.write_text(
        f"proto={proto}\nstart={stamp}\nserver={cfg['SERVER_IP']}\npicoquic={cfg['PICOQUIC_COMMIT']}\n"
        f"files={files}\nreps={args.reps}\nseed={seed}\nlabel={args.label}\n"
        f"ALT_PATHS={alt}\nPRIMARY_IF={os.environ.get('PRIMARY_IF', '')}\npath_ifaces={ifaces}\n"
        f"cipher={cfg.get('CLIENT_CIPHER', '')}\ncc={cfg.get('CONGESTION_CONTROL', '')}\n"
        f"dl_dir={outdir}\n{meta_extra}"
        f"host={os.uname().nodename} {os.uname().sysname} {os.uname().release} {os.uname().machine}\n"
        f"throttled_start={pi_throttled()}\nsoc_temp_start={soc_temp_c()}\n")

    rx_cols = []
    for i in ifaces:
        rx_cols += [f"rx_{i}", f"rx_share_{i}"]
    cols = COMMON_COLS + rx_cols + extra_cols + ["log"]

    csv_path = resdir / "runs.csv"
    total = args.reps * len(files)
    k = 0
    with open(csv_path, "w", newline="") as fcsv:
        w = csv.DictWriter(fcsv, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for rep in range(1, args.reps + 1):
            order = files[:]
            rng.shuffle(order)
            for pos, fname in enumerate(order):
                k += 1
                tag = f"r{rep:03d}_{fname}"
                ts = dt.datetime.now().isoformat(timespec="seconds")
                target = outdir / fname
                if target.exists():
                    target.unlink()

                rx0 = rx_bytes(ifaces)
                ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
                t0 = time.monotonic()
                out, rc, prow, dur = download_fn(fname, outdir, logdir, tag, args.timeout)
                wall = time.monotonic() - t0
                ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
                rx1 = rx_bytes(ifaces)
                cpu = (ru1.ru_utime - ru0.ru_utime) + (ru1.ru_stime - ru0.ru_stime)

                ok = int(target.exists() and sha256(target) == ref[fname])
                fbytes = target.stat().st_size if target.exists() else 0
                row = {
                    "ts": ts, "proto": proto, "label": args.label, "rep": rep, "order": pos,
                    "file": fname, "file_bytes": fbytes, "exit_code": rc, "ok": ok,
                    "duration_s": f"{dur:.6f}" if dur else "",
                    "goodput_mbps": f"{fbytes * 8 / dur / 1e6:.3f}" if (ok and dur) else "",
                    "wall_s": f"{wall:.3f}", "cpu_s": f"{cpu:.3f}",
                    "cpu_pct": f"{100 * cpu / wall:.1f}" if wall > 0 else "",
                    "soc_temp_c": soc_temp_c(),
                    "log": f"logs/{tag}.log",
                }
                deltas = {i: (rx1[i] - rx0[i]) if None not in (rx0[i], rx1[i]) else None for i in ifaces}
                tot = sum(d for d in deltas.values() if d) or 1
                for i, d in deltas.items():
                    row[f"rx_{i}"] = d if d is not None else ""
                    row[f"rx_share_{i}"] = f"{d / tot:.3f}" if d is not None else ""
                row.update(prow)
                w.writerow(row)
                fcsv.flush()

                shares = " ".join(f"{i}={row[f'rx_share_{i}']}" for i in ifaces)
                print(f"[{k}/{total}] {proto:6s} {tag:28s} ok={ok} rc={rc} mp={row.get('mp_active', '')} "
                      f"paths={row.get('nb_paths', '') or '-'} {row['goodput_mbps'] or '-':>9} Mbps  "
                      f"cpu={row['cpu_pct']:>5}%  rx: {shares}", flush=True)
                if target.exists():
                    target.unlink()
                time.sleep(args.pause)

    shutil.rmtree(outdir, ignore_errors=True)
    with open(meta, "a") as fm:
        fm.write(f"end={dt.datetime.now().strftime('%Y%m%d-%H%M%S')}\n"
                 f"throttled_end={pi_throttled()}\nsoc_temp_end={soc_temp_c()}\n")
    th = pi_throttled()
    if th and th != "0x0":
        print(f"\nWARNING: vcgencmd get_throttled={th}: the Pi throttled or was under-voltage "
              f"during or before the run; results may be CPU-limited. Check cooling and the PSU.")
    print(f"\nResults: {csv_path}\nAnalyse: python3 analysis/analyze.py {csv_path}")
