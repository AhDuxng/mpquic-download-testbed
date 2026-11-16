#!/usr/bin/env python3
"""
File        : client/run_experiment.py
Project     : mpquic-download-testbed
Description : Repeated multipath QUIC (picoquic) download experiment.

Every run starts a fresh picoquicdemo client with multipath enabled (-M) and
the extra paths given in ALT_PATHS (-A), in an empty working directory (no
session ticket: full handshake, no 0-RTT). One file is downloaded over HTTP/3,
its SHA-256 is checked against the server's SHA256SUMS, and one row is appended
to runs.csv. The order of the files is shuffled in every repetition so that
slow network drift affects all files equally. Failed or corrupted downloads are
kept in the CSV with ok=0 so the success rate stays visible.

Usage       : ALT_PATHS=<ip>/<ifindex> client/run_experiment.py [options]
Examples    : ALT_PATHS=10.50.40.68/3 client/run_experiment.py -n 30
              PRIMARY_IF=2 ALT_PATHS=10.50.40.68/3 client/run_experiment.py \\
                  -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"

Environment : ALT_PATHS (required), PRIMARY_IF (optional); see client/download.sh.

Output      : results/<stamp>/runs.csv   one row per download; per-path columns
                                         pN_local, pN_bytes, pN_share, pN_srtt_ms,
                                         pN_rtt_min_ms, pN_losses (N = 0..2)
              results/<stamp>/meta.txt   seed, picoquic commit, ALT_PATHS, host,
                                         Raspberry Pi throttling state
              results/<stamp>/logs/      full client output of every run

Metrics     : goodput_mbps = file bytes / picoquic connection duration
              (handshake included). cpu_pct = client CPU time / wall time;
              ~100 means one core was saturated. soc_temp_c is read from
              thermal_zone0 when available.
"""
import argparse
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
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin" / "picoquicdemo"
MAX_PATHS = 3

RE_RECV = re.compile(r"Received (\d+) bytes in ([\d.]+) seconds")
RE_MP = re.compile(r"Enable multipath: (\w+)")
RE_SUM = re.compile(r"MPSTAT_SUMMARY multipath=(\d+) nb_paths=(\d+)")
RE_PATH = re.compile(
    r"MPSTAT path=(\d+) unique_id=(\d+) local=(\S+) peer=(\S+) bytes_received=(\d+) "
    r"bytes_sent=(\d+) srtt_us=(\d+) rtt_min_us=(\d+) lost_bytes=(\d+) losses=(\d+)")


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


def client_args(cfg, alt_paths, outdir, qlog_dir):
    args = [str(BIN), "-n", cfg["SERVER_SNI"], "-o", str(outdir), "-M", "-A", alt_paths]
    if cfg.get("CLIENT_CIPHER"):
        args += ["-C", cfg["CLIENT_CIPHER"]]
    if os.environ.get("PRIMARY_IF"):
        args += ["-e", os.environ["PRIMARY_IF"]]
    if qlog_dir:
        args += ["-q", str(qlog_dir)]
    return args


def run_once(fname, cfg, alt_paths, outdir, logdir, tag, timeout, qlog):
    qlog_dir = logdir / "qlog" / tag if qlog else None
    if qlog_dir:
        qlog_dir.mkdir(parents=True, exist_ok=True)
    args = client_args(cfg, alt_paths, outdir, qlog_dir)
    args += [cfg["SERVER_IP"], cfg["SERVER_PORT"], "/" + fname]
    target = outdir / fname
    if target.exists():
        target.unlink()

    work = tempfile.mkdtemp(prefix="mpq_")
    ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    try:
        p = subprocess.run(args, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True, errors="replace")
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        rc = "timeout"
    finally:
        shutil.rmtree(work, ignore_errors=True)
    wall = time.monotonic() - t0
    ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (ru1.ru_utime - ru0.ru_utime) + (ru1.ru_stime - ru0.ru_stime)

    log_path = logdir / f"{tag}.log"
    log_path.write_text(" ".join(args) + "\n\n" + out)
    return out, rc, wall, cpu, target, log_path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--reps", type=int, default=10, help="repetitions per file")
    ap.add_argument("-f", "--files", default=None, help="comma list; default = all TEST_FILES")
    ap.add_argument("-t", "--timeout", type=int, default=300, help="seconds per download")
    ap.add_argument("-p", "--pause", type=float, default=1.0, help="seconds between runs")
    ap.add_argument("--qlog", action="store_true", help="write qlog for every run (large!)")
    ap.add_argument("--label", default="", help="free text stored in every row, e.g. 'eth0+wlan0'")
    ap.add_argument("--seed", type=int, default=None, help="shuffle seed (recorded)")
    ap.add_argument("--dl-dir", default=None,
                    help="where files are written before the SHA check; default CLIENT_DL_DIR "
                         "(/dev/shm = RAM) so SD-card speed does not limit the download")
    a = ap.parse_args()

    if not BIN.exists():
        sys.exit("Build first: ./install_picoquic.sh")
    alt_paths = os.environ.get("ALT_PATHS", "").strip()
    if not alt_paths:
        sys.exit("ALT_PATHS is required, e.g. ALT_PATHS=10.50.40.68/3 (see README, multipath setup)")
    cfg = load_config()
    files = ([f.strip() for f in a.files.split(",")] if a.files
             else [s.split(":")[0] for s in cfg["TEST_FILES"].split()])
    seed = a.seed if a.seed is not None else random.randrange(1 << 31)
    rng = random.Random(seed)

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    resdir = ROOT / "results" / stamp
    logdir = resdir / "logs"
    logdir.mkdir(parents=True)
    dl = a.dl_dir or cfg.get("CLIENT_DL_DIR") or str(resdir / "downloads")
    if not a.dl_dir and not Path("/dev/shm").is_dir():
        dl = str(resdir / "downloads")
    outdir = Path(dl) / stamp
    outdir.mkdir(parents=True, exist_ok=True)

    _, rc, _, _, sums_path, _ = run_once("SHA256SUMS", cfg, alt_paths, outdir, logdir,
                                         "000_SHA256SUMS", 60, False)
    if not sums_path.exists():
        shutil.rmtree(outdir, ignore_errors=True)
        sys.exit(f"Cannot fetch SHA256SUMS from server (rc={rc}). See {logdir}/000_SHA256SUMS.log")
    ref = {}
    for line in sums_path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            ref[parts[1].lstrip("*")] = parts[0]
    missing = [f for f in files if f not in ref]
    if missing:
        shutil.rmtree(outdir, ignore_errors=True)
        shutil.rmtree(resdir, ignore_errors=True)
        sys.exit(f"Not on the server (absent from SHA256SUMS): {', '.join(missing)}. "
                 f"Use -f or run server/gen_testfiles.sh.")

    meta = resdir / "meta.txt"
    meta.write_text(
        f"start={stamp}\nserver={cfg['SERVER_IP']}:{cfg['SERVER_PORT']}\npicoquic={cfg['PICOQUIC_COMMIT']}\n"
        f"mode=mp\nfiles={files}\nreps={a.reps}\nseed={seed}\nlabel={a.label}\n"
        f"ALT_PATHS={alt_paths}\nPRIMARY_IF={os.environ.get('PRIMARY_IF', '')}\n"
        f"cipher={cfg.get('CLIENT_CIPHER', '')}\ndl_dir={outdir}\n"
        f"host={os.uname().nodename} {os.uname().sysname} {os.uname().release} {os.uname().machine}\n"
        f"throttled_start={pi_throttled()}\nsoc_temp_start={soc_temp_c()}\n")

    cols = ["ts", "label", "rep", "order", "file", "file_bytes", "exit_code", "ok",
            "mp_negotiated", "nb_paths", "conn_bytes_received", "duration_s", "goodput_mbps",
            "wall_s", "cpu_s", "cpu_pct", "soc_temp_c"]
    for i in range(MAX_PATHS):
        cols += [f"p{i}_local", f"p{i}_bytes", f"p{i}_share", f"p{i}_srtt_ms", f"p{i}_rtt_min_ms", f"p{i}_losses"]
    cols.append("log")

    csv_path = resdir / "runs.csv"
    total = a.reps * len(files)
    k = 0
    with open(csv_path, "w", newline="") as fcsv:
        w = csv.DictWriter(fcsv, fieldnames=cols)
        w.writeheader()
        for rep in range(1, a.reps + 1):
            order = files[:]
            rng.shuffle(order)
            for pos, fname in enumerate(order):
                k += 1
                tag = f"r{rep:03d}_{fname}"
                ts = dt.datetime.now().isoformat(timespec="seconds")
                out, rc, wall, cpu, target, log_path = run_once(
                    fname, cfg, alt_paths, outdir, logdir, tag, a.timeout, a.qlog)

                ok = int(target.exists() and sha256(target) == ref[fname])
                fbytes = target.stat().st_size if target.exists() else 0
                m_recv = RE_RECV.search(out)
                m_sum = RE_SUM.search(out)
                m_mp = RE_MP.search(out)
                dur = float(m_recv.group(2)) if m_recv else None
                if m_mp:
                    mp_ok = int(m_mp.group(1) == "Success")
                elif m_sum:
                    mp_ok = int(m_sum.group(1) == "1")
                else:
                    mp_ok = ""
                row = {
                    "ts": ts, "label": a.label, "rep": rep, "order": pos, "file": fname,
                    "file_bytes": fbytes, "exit_code": rc, "ok": ok,
                    "mp_negotiated": mp_ok,
                    "nb_paths": m_sum.group(2) if m_sum else "",
                    "conn_bytes_received": m_recv.group(1) if m_recv else "",
                    "duration_s": f"{dur:.6f}" if dur else "",
                    "goodput_mbps": f"{fbytes * 8 / dur / 1e6:.3f}" if (ok and dur) else "",
                    "wall_s": f"{wall:.3f}", "cpu_s": f"{cpu:.3f}",
                    "cpu_pct": f"{100 * cpu / wall:.1f}" if wall > 0 else "",
                    "soc_temp_c": soc_temp_c(),
                    "log": str(log_path.relative_to(resdir)),
                }
                paths = [mm.groups() for mm in RE_PATH.finditer(out)][:MAX_PATHS]
                tot = sum(int(p[4]) for p in paths) or 1
                for p in paths:
                    i = int(p[0])
                    if i >= MAX_PATHS:
                        continue
                    row[f"p{i}_local"] = p[2]
                    row[f"p{i}_bytes"] = p[4]
                    row[f"p{i}_share"] = f"{int(p[4]) / tot:.3f}"
                    row[f"p{i}_srtt_ms"] = f"{int(p[6]) / 1000:.2f}"
                    row[f"p{i}_rtt_min_ms"] = f"{int(p[7]) / 1000:.2f}"
                    row[f"p{i}_losses"] = p[9]
                w.writerow(row)
                fcsv.flush()

                shares = " ".join(f"p{p[0]}={row.get(f'p{p[0]}_share', '-')}" for p in paths)
                print(f"[{k}/{total}] {tag:32s} ok={ok} rc={rc} mp={mp_ok} "
                      f"{row['goodput_mbps'] or '-':>9} Mbps  cpu={row['cpu_pct']:>5}%  "
                      f"paths={row['nb_paths'] or '-'} {shares}")
                if target.exists():
                    target.unlink()
                time.sleep(a.pause)

    shutil.rmtree(outdir, ignore_errors=True)
    with open(meta, "a") as fm:
        fm.write(f"end={dt.datetime.now().strftime('%Y%m%d-%H%M%S')}\n"
                 f"throttled_end={pi_throttled()}\nsoc_temp_end={soc_temp_c()}\n")
    th = pi_throttled()
    if th and th != "0x0":
        print(f"\nWARNING: vcgencmd get_throttled={th}: the Pi throttled or was under-voltage "
              f"during or before the run; results may be CPU-limited. Check cooling and the PSU.")
    print(f"\nResults: {csv_path}\nAnalyse: python3 analysis/analyze.py {csv_path}")


if __name__ == "__main__":
    main()
