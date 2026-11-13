#!/usr/bin/env bash
# Linux client only: emulate path conditions on the DOWNLOAD direction of one
# interface (ingress redirected to an ifb device, then netem).
#
#   sudo client/shape_paths.sh add  <iface> <rate> <delay> [loss]
#   sudo client/shape_paths.sh del  <iface>
#   sudo client/shape_paths.sh show
#
# Example: path A 20 Mbit/s +10 ms, path B 5 Mbit/s +60 ms, 0.5 % loss
#   sudo client/shape_paths.sh add eth0  20mbit 10ms
#   sudo client/shape_paths.sh add wlan0 5mbit  60ms 0.5%
#
# Notes:
# - The added delay is on the downlink only, so RTT grows by <delay>.
# - netem stacks on top of the real link; the effective rate is min(real, <rate>).
# - Record the shaping you used in --label of run_experiment.py.
set -euo pipefail

CMD="${1:?add|del|show}"
ifb_of() { echo "ifb_${1:0:10}"; }

case "$CMD" in
add)
    IF="${2:?iface}"; RATE="${3:?rate e.g. 20mbit}"; DELAY="${4:?delay e.g. 30ms}"; LOSS="${5:-0%}"
    IFB="$(ifb_of "$IF")"
    modprobe ifb 2>/dev/null || true
    "$0" del "$IF" >/dev/null 2>&1 || true
    ip link add "$IFB" type ifb
    ip link set "$IFB" up
    tc qdisc add dev "$IF" handle ffff: ingress
    tc filter add dev "$IF" parent ffff: protocol all u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB"
    tc qdisc add dev "$IFB" root netem rate "$RATE" delay "$DELAY" loss "$LOSS" limit 100000
    echo "Shaped downlink of $IF: rate=$RATE delay=$DELAY loss=$LOSS (via $IFB)"
    ;;
del)
    IF="${2:?iface}"; IFB="$(ifb_of "$IF")"
    tc qdisc del dev "$IF" ingress 2>/dev/null || true
    ip link del "$IFB" 2>/dev/null || true
    echo "Removed shaping on $IF"
    ;;
show)
    tc -s qdisc show | grep -A2 -E "netem|ingress" || echo "no shaping"
    ;;
*)
    echo "usage: $0 add|del|show ..." >&2; exit 1 ;;
esac
