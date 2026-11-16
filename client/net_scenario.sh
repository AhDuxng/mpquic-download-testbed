#!/usr/bin/env bash
# =============================================================================
# File        : client/net_scenario.sh
# Project     : mpquic-download-testbed
# Description : Linux client only. Applies one of the predefined network
#               scenarios to one or more interfaces: a token-bucket bandwidth
#               bottleneck (tbf) with a netem child for delay, jitter and loss.
#
# Usage       : sudo client/net_scenario.sh <low|medium|high|clear|show> <iface> [iface ...]
# Example     : sudo client/net_scenario.sh medium wlan0 eth0
#               sudo client/net_scenario.sh clear  wlan0 eth0
#
# Scenarios   :            rate      delay   jitter (normal)   loss
#               low        40 Mbit   20 ms   0 ms              0 %
#               medium     40 Mbit   20 ms   4 ms              1.5 %
#               high       40 Mbit   20 ms   16 ms             3 %
#               tbf: burst 16 kB, latency 400 ms; netem: limit 1000 packets.
#
# Direction   : DIRECTION=ingress (default) shapes the DOWNLOAD direction, the
#               one that carries the file data: ingress traffic of <iface> is
#               redirected to an ifb device (ifb_<iface>) whose root qdisc is
#               the scenario. DIRECTION=egress applies the scenario to the root
#               qdisc of <iface> itself (upload direction: requests and ACKs).
#               In both cases the delay adds 20 ms to the round-trip time.
#
# Notes       : The shaping stacks on the real link, so the effective rate is
#               min(real, 40 Mbit). Applying a scenario first clears the
#               previous one on the same interface. `clear` restores the
#               default qdisc in both directions.
# =============================================================================
set -euo pipefail

SCENARIO="${1:?usage: $0 <low|medium|high|clear|show> <iface> [iface ...]}"
shift
[ $# -ge 1 ] || { echo "usage: $0 <low|medium|high|clear|show> <iface> [iface ...]" >&2; exit 1; }
DIRECTION="${DIRECTION:-ingress}"

RATE="40mbit"
BURST="16kb"
TBF_LATENCY="400ms"
NETEM_LIMIT="1000"
DELAY="20ms"

ifb_of() { echo "ifb_${1:0:10}"; }

clear_iface() {
    local dev="$1" ifb
    ifb="$(ifb_of "$dev")"
    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
    ip link del "$ifb" 2>/dev/null || true
}

apply_qdisc() {
    local dev="$1" jitter="$2" loss="$3"
    tc qdisc add dev "$dev" root handle 1: tbf rate "$RATE" burst "$BURST" latency "$TBF_LATENCY"
    if [ "$jitter" = "0ms" ]; then
        tc qdisc add dev "$dev" parent 1:1 handle 10: netem limit "$NETEM_LIMIT" \
            delay "$DELAY" loss "$loss"
    else
        tc qdisc add dev "$dev" parent 1:1 handle 10: netem limit "$NETEM_LIMIT" \
            delay "$DELAY" "$jitter" distribution normal loss "$loss"
    fi
}

apply_iface() {
    local dev="$1" jitter="$2" loss="$3" ifb
    clear_iface "$dev"
    case "$DIRECTION" in
        ingress)
            ifb="$(ifb_of "$dev")"
            modprobe ifb 2>/dev/null || true
            ip link add "$ifb" type ifb
            ip link set "$ifb" up
            tc qdisc add dev "$dev" handle ffff: ingress
            tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 \
                action mirred egress redirect dev "$ifb"
            apply_qdisc "$ifb" "$jitter" "$loss"
            ;;
        egress)
            apply_qdisc "$dev" "$jitter" "$loss"
            ;;
        *)
            echo "DIRECTION must be ingress or egress" >&2; exit 1 ;;
    esac
    echo "$dev: scenario $SCENARIO ($DIRECTION) rate=$RATE delay=$DELAY jitter=$jitter loss=$loss"
}

show_iface() {
    local dev="$1" ifb
    ifb="$(ifb_of "$dev")"
    echo "=== $dev ==="
    tc -s qdisc show dev "$dev" | grep -E "qdisc (tbf|netem|ingress)" -A2 || echo "  no scenario on $dev"
    if ip link show "$ifb" >/dev/null 2>&1; then
        echo "=== $ifb (ingress of $dev) ==="
        tc -s qdisc show dev "$ifb"
    fi
}

for dev in "$@"; do
    case "$SCENARIO" in
        low)         apply_iface "$dev" "0ms"  "0%" ;;
        medium)      apply_iface "$dev" "4ms"  "1.5%" ;;
        high)        apply_iface "$dev" "16ms" "3%" ;;
        clear|reset) clear_iface "$dev"; echo "$dev: cleared" ;;
        show)        show_iface "$dev" ;;
        *)           echo "unknown scenario: $SCENARIO" >&2; exit 1 ;;
    esac
done
