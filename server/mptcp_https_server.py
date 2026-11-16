#!/usr/bin/env python3
"""
File        : server/mptcp_https_server.py
Project     : mpquic-download-testbed
Description : HTTPS file server over Multipath TCP, the MPTCP counterpart of the
              picoquic HTTP/3 server. Serves the same www/ directory with the
              same certificate, so both protocols download identical files.

Usage       : mptcp_https_server.py --www DIR --cert FILE --key FILE
                                    [--port 8443] [--cc cubic] [--log FILE]

Transport   : The listening socket is created with IPPROTO_MPTCP; the kernel
              accepts MP_CAPABLE connections and MP_JOIN subflows, and falls
              back to plain TCP for clients without MPTCP. The congestion
              control is set per socket (TCP_CONGESTION) to match the
              CONGESTION_CONTROL used by the QUIC server.
TLS         : TLS 1.3 only; the client chooses the cipher suite.
HTTP        : HTTP/1.1 GET and HEAD of static files, one thread per connection.
              The TLS handshake runs in the connection thread, so a slow client
              never blocks the accept loop.
Requires    : Linux kernel with net.mptcp.enabled = 1, Python >= 3.10.
"""
import argparse
import functools
import http.server
import socket
import socketserver
import ssl
import sys


class MPTCPHTTPSServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, addr, handler, ctx, cc):
        self.ctx, self.cc = ctx, cc
        super().__init__(addr, handler, bind_and_activate=False)
        self.socket.close()
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_MPTCP)
        self._set_cc(self.socket)
        self.server_bind()
        self.server_activate()

    def _set_cc(self, sock):
        if self.cc:
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, self.cc.encode())
            except OSError as e:
                print(f"warning: TCP_CONGESTION={self.cc} not applied: {e}", file=sys.stderr)

    def finish_request(self, request, client_address):
        self._set_cc(request)
        try:
            tls = self.ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return
        super().finish_request(tls, client_address)


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mptcp-https"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.log_date_time_string()} {self.client_address[0]} {fmt % args}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--www", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--cc", default="cubic")
    a = ap.parse_args()

    if not hasattr(socket, "IPPROTO_MPTCP"):
        sys.exit("Python has no IPPROTO_MPTCP (needs Linux and Python >= 3.10)")
    try:
        if open("/proc/sys/net/mptcp/enabled").read().strip() != "1":
            sys.exit("MPTCP is disabled: sudo sysctl -w net.mptcp.enabled=1")
    except OSError:
        sys.exit("Kernel without MPTCP support (/proc/sys/net/mptcp/enabled missing)")

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(a.cert, a.key)

    handler = functools.partial(Handler, directory=a.www)
    srv = MPTCPHTTPSServer(("0.0.0.0", a.port), handler, ctx, a.cc)
    print(f"MPTCP HTTPS server on tcp/{a.port}, www={a.www}, cc={a.cc}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
