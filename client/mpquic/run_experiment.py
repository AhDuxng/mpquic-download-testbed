#!/usr/bin/env python3
"""
File        : client/mpquic/run_experiment.py
Project     : mpquic-download-testbed
Description : Repeated multipath QUIC (picoquic, HTTP/3) download experiment.

Every run starts a fresh picoquicdemo client with multipath enabled (-M) and
the extra paths given in ALT_PATHS (-A), in an empty working directory (no
session ticket: full handshake, no 0-RTT), downloads one file from the server's
www/ directory, verifies its SHA-256 and appends one row to runs.csv. The order
of the files is shuffled in every repetition. Failed or corrupted downloads are
kept with ok=0. The measurement harness is shared with client/mptcp/ (see
client/lib/testbed.py), so both protocols are measured identically.

Usage       : ALT_PATHS=<ip>/<ifindex> client/mpquic/run_experiment.py [options]
Examples    : ALT_PATHS=10.50.40.68/3 client/mpquic/run_experiment.py -n 30
              PRIMARY_IF=2 ALT_PATHS=10.50.40.68/3 client/mpquic/run_experiment.py \\
                  -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"

Environment : ALT_PATHS (required), PRIMARY_IF (optional); see download.sh.

Output      : results/mpquic/<stamp>/runs.csv, meta.txt, logs/
Columns     : common columns (see testbed.py) plus, from the MPSTAT lines of the
              patched client: mp_negotiated, and per path N = 0..2: pN_local,
              pN_bytes, pN_share, pN_srtt_ms, pN_rtt_min_ms, pN_losses.
              mp_active = multipath negotiated and at least two paths received
              data. duration_s = picoquic connection duration (handshake
              included).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import testbed as tb  # noqa: E402

BIN = tb.ROOT / "bin" / "picoquicdemo"
MAX_PATHS = 3

RE_RECV = re.compile(r"Received (\d+) bytes in ([\d.]+) seconds")
RE_MP = re.compile(r"Enable multipath: (\w+)")
RE_SUM = re.compile(r"MPSTAT_SUMMARY multipath=(\d+) nb_paths=(\d+)")
RE_PATH = re.compile(
    r"MPSTAT path=(\d+) unique_id=(\d+) local=(\S+) peer=(\S+) bytes_received=(\d+) "
    r"bytes_sent=(\d+) srtt_us=(\d+) rtt_min_us=(\d+) lost_bytes=(\d+) losses=(\d+)")

EXTRA_COLS = ["mp_negotiated"]
for _i in range(MAX_PATHS):
    EXTRA_COLS += [f"p{_i}_local", f"p{_i}_bytes", f"p{_i}_share", f"p{_i}_srtt_ms",
                   f"p{_i}_rtt_min_ms", f"p{_i}_losses"]


def make_download(cfg, alt, qlog):
    def download(fname, outdir, logdir, tag, timeout):
        args = [str(BIN), "-n", cfg["SERVER_SNI"], "-o", str(outdir), "-M", "-A", alt]
        if cfg.get("CLIENT_CIPHER"):
            args += ["-C", cfg["CLIENT_CIPHER"]]
        if os.environ.get("PRIMARY_IF"):
            args += ["-e", os.environ["PRIMARY_IF"]]
        if qlog:
            qdir = logdir / "qlog" / tag
            qdir.mkdir(parents=True, exist_ok=True)
            args += ["-q", str(qdir)]
        args += [cfg["SERVER_IP"], cfg["SERVER_PORT"], "/" + fname]

        work = tempfile.mkdtemp(prefix="mpq_")
        try:
            p = subprocess.run(args, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout, text=True, errors="replace")
            out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            rc = "timeout"
        finally:
            shutil.rmtree(work, ignore_errors=True)
        (logdir / f"{tag}.log").write_text(" ".join(args) + "\n\n" + out)

        m_recv, m_sum, m_mp = RE_RECV.search(out), RE_SUM.search(out), RE_MP.search(out)
        dur = float(m_recv.group(2)) if m_recv else None
        if m_mp:
            negotiated = int(m_mp.group(1) == "Success")
        elif m_sum:
            negotiated = int(m_sum.group(1) == "1")
        else:
            negotiated = ""
        paths = [mm.groups() for mm in RE_PATH.finditer(out)][:MAX_PATHS]
        used = sum(1 for pp in paths if int(pp[4]) > 0)
        tot = sum(int(pp[4]) for pp in paths) or 1
        row = {"mp_negotiated": negotiated,
               "mp_active": int(negotiated == 1 and used >= 2) if negotiated != "" else "",
               "nb_paths": m_sum.group(2) if m_sum else ""}
        for pp in paths:
            i = int(pp[0])
            if i >= MAX_PATHS:
                continue
            row.update({f"p{i}_local": pp[2], f"p{i}_bytes": pp[4],
                        f"p{i}_share": f"{int(pp[4]) / tot:.3f}",
                        f"p{i}_srtt_ms": f"{int(pp[6]) / 1000:.2f}",
                        f"p{i}_rtt_min_ms": f"{int(pp[7]) / 1000:.2f}", f"p{i}_losses": pp[9]})
        return out, rc, row, dur
    return download


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    tb.common_args(ap)
    ap.add_argument("--qlog", action="store_true", help="write qlog for every run (large!)")
    a = ap.parse_args()

    if not BIN.exists():
        sys.exit("Build first: ./install_picoquic.sh")
    alt = tb.alt_paths()
    cfg = tb.load_config()
    tb.run_experiment("mpquic", a, cfg, alt, make_download(cfg, alt, a.qlog), EXTRA_COLS,
                      meta_extra=f"port=udp/{cfg['SERVER_PORT']}\n")


if __name__ == "__main__":
    main()
