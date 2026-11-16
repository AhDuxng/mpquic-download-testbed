#!/usr/bin/env python3
"""
File        : client/mptcp/run_experiment.py
Project     : mpquic-download-testbed
Description : Repeated Multipath TCP (HTTPS over MPTCP, TLS 1.3) download
              experiment, the MPTCP counterpart of client/mpquic/run_experiment.py.

Every run starts a fresh curl process with --mptcp (or mptcpize), which
downloads one file from the server's www/ directory through the MPTCP HTTPS
server, then verifies its SHA-256 and appends one row to runs.csv. Extra
subflows are opened by the kernel path manager from the endpoints configured
with setup_mptcp.sh, i.e. on the same interfaces as ALT_PATHS. The measurement
harness is shared with client/mpquic/ (see client/lib/testbed.py).

Usage       : ALT_PATHS=<ip>/<ifindex> client/mptcp/run_experiment.py [options]
Example     : sudo client/mptcp/setup_mptcp.sh add 10.50.40.68/3
              PRIMARY_IF=2 ALT_PATHS=10.50.40.68/3 client/mptcp/run_experiment.py \\
                  -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"

Environment : ALT_PATHS (required, must match the configured MPTCP endpoints),
              PRIMARY_IF (optional, selects the interface of path 0 for the
              per-interface byte counters).

Output      : results/mptcp/<stamp>/runs.csv, meta.txt, logs/
Columns     : common columns (see testbed.py) plus mptcp_capable (SYN/ACK
              carried MP_CAPABLE: no fallback to plain TCP), mptcp_fallback,
              subflows_joined (MP_JOIN handshakes completed), http_code,
              t_connect_s, t_tls_s, t_first_byte_s (curl timings).
              nb_paths = 1 + subflows_joined. mp_active = MPTCP negotiated, at
              least one subflow joined and, when two or more interfaces are
              known, at least two of them received >= 1 % of the file size.
              duration_s = curl time_total (TCP and TLS handshakes included),
              the same definition as for MPQUIC.

Counters    : MPTCP MIB counters are read from /proc/net/netstat before and
              after each download. They are host-wide: do not run other MPTCP
              traffic during an experiment.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import testbed as tb  # noqa: E402

TLS13 = {"20": "TLS_CHACHA20_POLY1305_SHA256", "128": "TLS_AES_128_GCM_SHA256",
         "256": "TLS_AES_256_GCM_SHA384"}
MIB = ["MPCapableSYNTX", "MPCapableSYNACKRX", "MPCapableFallbackSYNACK", "MPJoinSynAckRx"]
RE_STAT = re.compile(r"CURLSTAT http=(\d+) size=(\d+) connect=([\d.]+) tls=([\d.]+) "
                     r"first_byte=([\d.]+) total=([\d.]+)")
EXTRA_COLS = ["mptcp_capable", "mptcp_fallback", "subflows_joined", "http_code",
              "t_connect_s", "t_tls_s", "t_first_byte_s"]


def curl_base():
    try:
        helptext = subprocess.run(["curl", "--help", "all"], capture_output=True, text=True,
                                  timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        sys.exit("curl not found")
    if "--mptcp" in helptext:
        return ["curl", "--mptcp"]
    if subprocess.run(["sh", "-c", "command -v mptcpize"], capture_output=True).returncode == 0:
        return ["mptcpize", "run", "curl"]
    sys.exit("curl has no --mptcp (needs >= 8.9) and mptcpize is missing (apt-get install mptcpd)")


def mptcp_mib():
    lines = [ln.split() for ln in Path("/proc/net/netstat").read_text().splitlines()
             if ln.startswith("MPTcpExt:")]
    if len(lines) < 2:
        return {}
    return {k: int(v) for k, v in zip(lines[0][1:], lines[1][1:])}


def check_endpoints(alt):
    out = subprocess.run(["ip", "mptcp", "endpoint", "show"], capture_output=True, text=True).stdout
    enabled = Path("/proc/sys/net/mptcp/enabled").read_text().strip() == "1"
    missing = [item.split("/")[0] for item in alt.split(",") if item.split("/")[0] not in out]
    if not enabled or missing:
        sys.exit(f"MPTCP is not configured for ALT_PATHS={alt} "
                 f"(enabled={int(enabled)}, missing endpoints: {', '.join(missing) or '-'}).\n"
                 f"Run: sudo client/mptcp/setup_mptcp.sh add {alt}")


def make_download(cfg, base, ifaces):
    cipher = TLS13.get(cfg.get("CLIENT_CIPHER", ""))

    def download(fname, outdir, logdir, tag, timeout):
        args = base + ["-k", "-sS", "-f", "--tlsv1.3", "--http1.1", "--max-time", str(timeout),
                       "--resolve", f"{cfg['SERVER_SNI']}:{cfg['MPTCP_PORT']}:{cfg['SERVER_IP']}",
                       "-o", str(outdir / fname),
                       "-w", "\nCURLSTAT http=%{http_code} size=%{size_download} connect=%{time_connect} "
                             "tls=%{time_appconnect} first_byte=%{time_starttransfer} total=%{time_total}\n"]
        if cipher:
            args += ["--tls13-ciphers", cipher]
        args.append(f"https://{cfg['SERVER_SNI']}:{cfg['MPTCP_PORT']}/{fname}")

        before = mptcp_mib()
        rx0 = tb.rx_bytes(ifaces)
        try:
            p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout + 10, text=True, errors="replace")
            out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            rc = "timeout"
        rx1 = tb.rx_bytes(ifaces)
        after = mptcp_mib()
        delta = {k: after.get(k, 0) - before.get(k, 0) for k in MIB}
        (logdir / f"{tag}.log").write_text(
            " ".join(args) + "\n\n" + out + "\n" + " ".join(f"{k}={v}" for k, v in delta.items()) + "\n")

        m = RE_STAT.search(out)
        capable = int(delta["MPCapableSYNACKRX"] > 0)
        joined = delta["MPJoinSynAckRx"]
        fsize = int(m.group(2)) if m else 0
        busy = sum(1 for i in ifaces
                   if None not in (rx0[i], rx1[i]) and fsize and rx1[i] - rx0[i] >= 0.01 * fsize)
        active = capable and joined >= 1 and (busy >= 2 or len(ifaces) < 2)
        row = {"mptcp_capable": capable, "mptcp_fallback": int(delta["MPCapableFallbackSYNACK"] > 0),
               "subflows_joined": joined, "nb_paths": 1 + joined if capable else 1,
               "mp_active": int(bool(active))}
        dur = None
        if m:
            dur = float(m.group(6)) or None
            row.update({"http_code": m.group(1), "t_connect_s": m.group(3), "t_tls_s": m.group(4),
                        "t_first_byte_s": m.group(5)})
        return out, rc, row, dur
    return download


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    tb.common_args(ap)
    a = ap.parse_args()

    alt = tb.alt_paths()
    cfg = tb.load_config()
    if not cfg.get("MPTCP_PORT"):
        sys.exit("MPTCP_PORT is not set in config.env")
    check_endpoints(alt)
    base = curl_base()
    ifaces = tb.path_ifaces(alt)
    tb.run_experiment("mptcp", a, cfg, alt, make_download(cfg, base, ifaces), EXTRA_COLS,
                      meta_extra=f"port=tcp/{cfg['MPTCP_PORT']}\nclient={' '.join(base)}\n")


if __name__ == "__main__":
    main()
