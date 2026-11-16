#!/usr/bin/env bash
# =============================================================================
# File        : client/mptcp/setup_mptcp.sh
# Project     : mpquic-download-testbed
# Description : Linux client only. Configures the in-kernel MPTCP path manager
#               so that every MPTCP connection opens one extra subflow from each
#               additional interface. Takes the same "ip/ifindex" list as
#               ALT_PATHS, so MPTCP and MPQUIC use exactly the same paths.
#
# Usage       : sudo client/mptcp/setup_mptcp.sh add <ip>/<ifindex>[,...]
#               sudo -E client/mptcp/setup_mptcp.sh add        (uses $ALT_PATHS)
#               sudo client/mptcp/setup_mptcp.sh show
#               sudo client/mptcp/setup_mptcp.sh del
#
# Effect      : add   net.mptcp.enabled=1; limits subflow=2 add_addr_accepted=2;
#                     replaces all endpoints with one "subflow" endpoint per
#                     listed address, bound to its interface.
#               del   removes all endpoints (MPTCP stays enabled, single subflow).
#
# Notes       : The initial subflow follows the default route (path 0). The
#               source-based policy routing of README section 7.3 is required
#               as well, otherwise the extra subflow leaves via the wrong
#               interface. Settings are not persistent across reboots.
#               NetworkManager may also manage MPTCP endpoints; check with
#               `show` after the interfaces come up.
# =============================================================================
set -euo pipefail

CMD="${1:?usage: $0 add [ip/ifindex,...] | show | del}"

ifname_of() {
    local idx="$1" d
    for d in /sys/class/net/*; do
        [ "$(cat "$d/ifindex" 2>/dev/null)" = "$idx" ] && { basename "$d"; return 0; }
    done
    return 1
}

case "$CMD" in
add)
    LIST="${2:-${ALT_PATHS:-}}"
    [ -n "$LIST" ] || { echo "give ip/ifindex[,...] or export ALT_PATHS (sudo -E)" >&2; exit 1; }
    sysctl -qw net.mptcp.enabled=1
    ip mptcp limits set subflow 2 add_addr_accepted 2
    ip mptcp endpoint flush
    IFS=',' read -ra ITEMS <<<"$LIST"
    for item in "${ITEMS[@]}"; do
        ip_addr="${item%%/*}"; idx="${item##*/}"
        dev="$(ifname_of "$idx")" || { echo "no interface with ifindex $idx" >&2; exit 1; }
        ip mptcp endpoint add "$ip_addr" dev "$dev" subflow
        echo "endpoint $ip_addr dev $dev (subflow)"
    done
    ip mptcp limits
    ;;
show)
    echo "net.mptcp.enabled = $(cat /proc/sys/net/mptcp/enabled)"
    ip mptcp limits
    ip mptcp endpoint show
    ;;
del)
    ip mptcp endpoint flush
    echo "All MPTCP endpoints removed."
    ;;
*)
    echo "usage: $0 add [ip/ifindex,...] | show | del" >&2; exit 1 ;;
esac
