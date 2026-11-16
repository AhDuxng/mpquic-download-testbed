#!/usr/bin/env bash
# =============================================================================
# File        : client/run_campaign.sh
# Project     : mpquic-download-testbed
# Description : Unattended measurement campaign (e.g. overnight). Repeats rounds
#               until a deadline; every round runs each network scenario
#               (client/net_scenario.sh) on all path interfaces, and inside each
#               scenario one block of MPQUIC and one block of MPTCP downloads
#               (client/<proto>/run_experiment.py). Scenario order and protocol
#               order are shuffled in every round, so slow drift of the real
#               network affects all combinations equally.
#
# Usage       : sudo -E client/run_campaign.sh [options]
#                 --until HH:MM       stop starting blocks that would end after
#                                     this time (next occurrence; default 07:00)
#                 --files a,b         files per block (default file_1MB.bin,
#                                     file_10MB.bin,file_50MB.bin)
#                 --reps N            repetitions of the file set per block (1)
#                 --scenarios a,b     default low,medium,high
#                 --protos a,b        default mpquic,mptcp
#                 --timeout S         per-download timeout in seconds (300)
#                 --poll S            wait between readiness checks (300)
# Environment : ALT_PATHS (required), PRIMARY_IF (optional), as for the runners.
#
# Readiness   : Checked before every round, with no scenario applied:
#                 1. every path interface reaches the server (ICMP);
#                 2. smoke test MPQUIC: a 1 MB download in which at least two
#                    paths receive data;
#                 3. smoke test MPTCP (only if TCP MPTCP_PORT is reachable):
#                    MP_CAPABLE accepted and at least one subflow joined.
#               If 1 or 2 fails the round is not run and the checks repeat
#               after --poll seconds, so a campaign may be started before the
#               network is ready. If 3 fails, the round runs without MPTCP.
#               Missing MPTCP endpoints for ALT_PATHS addresses are added. The source-based routing table
#               of every additional path is given a default route through the
#               gateway of its interface.
#
# Output      : results/campaign-<stamp>/
#                 campaign.log           decisions, readiness, block durations
#                 mpquic/<block>/ , mptcp/<block>/   runner outputs (runs.csv)
#                 mpquic.out, mptcp.out  runner console output
#                 summary.txt            analysis/analyze.py over all blocks
#
# Safety      : Runs as root (tc, ip); the runners run as the invoking user.
#               The scenario is cleared after every block and on exit or
#               interruption. Stop early with: sudo kill <pid in campaign.pid>.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

[ "$(id -u)" = "0" ] || { echo "run as root: sudo -E $0 ..." >&2; exit 1; }
RUN_USER="${SUDO_USER:-}"
[ -n "$RUN_USER" ] && [ "$RUN_USER" != "root" ] || { echo "start it with sudo from a normal user" >&2; exit 1; }
ALT_PATHS="${ALT_PATHS:?ALT_PATHS is required, e.g. ALT_PATHS=192.168.8.107/2}"

UNTIL="07:00"
FILES="file_1MB.bin,file_10MB.bin,file_50MB.bin"
REPS=1
SCENARIOS="low,medium,high"
PROTOS="mpquic,mptcp"
TIMEOUT=300
POLL=300
while [ $# -gt 0 ]; do
    case "$1" in
        --until)     UNTIL="$2"; shift 2 ;;
        --files)     FILES="$2"; shift 2 ;;
        --reps)      REPS="$2"; shift 2 ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --protos)    PROTOS="$2"; shift 2 ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --poll)      POLL="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done

DEADLINE="$(date -d "$UNTIL" +%s)"
[ "$DEADLINE" -le "$(date +%s)" ] && DEADLINE="$(date -d "tomorrow $UNTIL" +%s)"

STAMP="$(date +%Y%m%d-%H%M%S)"
C="$ROOT/results/campaign-$STAMP"
mkdir -p "$C"
chown -R "$RUN_USER": "$ROOT/results" "$C"
LOG="$C/campaign.log"
echo $$ > "$C/campaign.pid"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

ifname_of() {
    local d
    for d in /sys/class/net/*; do
        [ "$(cat "$d/ifindex" 2>/dev/null)" = "$1" ] && { basename "$d"; return 0; }
    done
    return 1
}

if [ -n "${PRIMARY_IF:-}" ]; then
    PRIMARY_DEV="$(ifname_of "$PRIMARY_IF")"
else
    PRIMARY_DEV="$(ip -o route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
fi
PATH_DEVS=("$PRIMARY_DEV")
ALT_IPS=()
ALT_DEVS=()
IFS=',' read -ra ITEMS <<<"$ALT_PATHS"
for item in "${ITEMS[@]}"; do
    dev="$(ifname_of "${item##*/}")" || { echo "no interface with ifindex ${item##*/}" >&2; exit 1; }
    ALT_IPS+=("${item%%/*}"); ALT_DEVS+=("$dev")
    [[ " ${PATH_DEVS[*]} " == *" $dev "* ]] || PATH_DEVS+=("$dev")
done

cleanup() {
    "$ROOT/client/net_scenario.sh" clear "${PATH_DEVS[@]}" >/dev/null 2>&1
    rm -f "$C/campaign.pid"
    chown -R "$RUN_USER": "$C" 2>/dev/null
    log "campaign end"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

ensure_routing() {
    local i ip dev gw tbl
    for i in "${!ALT_IPS[@]}"; do
        ip="${ALT_IPS[$i]}"; dev="${ALT_DEVS[$i]}"
        gw="$(ip -4 route show default dev "$dev" | awk '/via/ { print $3; exit }')"
        [ -n "$gw" ] || { log "routing: no default gateway on $dev"; continue; }
        tbl="$(ip rule show | awk -v a="$ip" '$2 == "from" && $3 == a { print $NF; exit }')"
        if [ -z "$tbl" ]; then
            tbl=$((100 + $(cat "/sys/class/net/$dev/ifindex")))
            ip rule add from "$ip" table "$tbl" priority "$tbl"
            log "routing: added rule from $ip table $tbl"
        fi
        ip route replace default via "$gw" dev "$dev" table "$tbl"
    done
}

ensure_endpoints() {
    local i
    for i in "${!ALT_IPS[@]}"; do
        ip mptcp endpoint show | grep -q "^${ALT_IPS[$i]} " && continue
        ip mptcp endpoint add "${ALT_IPS[$i]}" dev "${ALT_DEVS[$i]}" subflow \
            && log "mptcp: added endpoint ${ALT_IPS[$i]} dev ${ALT_DEVS[$i]}"
    done
}

path_ok()  { ping -c 3 -W 2 -I "$1" "$SERVER_IP" >/dev/null 2>&1; }
mptcp_ok() { timeout 6 bash -c "exec 3<>/dev/tcp/$SERVER_IP/$MPTCP_PORT" 2>/dev/null; }

as_user() {
    sudo -u "$RUN_USER" env ALT_PATHS="$ALT_PATHS" PRIMARY_IF="${PRIMARY_IF:-}" "$@"
}

smoke_mpquic() {
    local out used
    out="$(as_user timeout 120 "$ROOT/client/mpquic/download.sh" file_1MB.bin 2>&1)"
    used="$(grep -cE "MPSTAT path=[0-9]+ .* bytes_received=[1-9]" <<<"$out")"
    log "smoke mpquic: $(grep -oE "Enable multipath: [A-Za-z]+" <<<"$out" | head -1),"\
        "paths with data: $used, $(grep -oE "Received [0-9]+ bytes in [0-9.]+ seconds" <<<"$out")"
    [ "$used" -ge 2 ]
}

smoke_mptcp() {
    local out
    out="$(as_user timeout 120 "$ROOT/client/mptcp/download.sh" file_1MB.bin 2>&1)"
    log "smoke mptcp: $(grep -oE "http=[0-9]+ size=[0-9]+" <<<"$out")" \
        "$(grep -E "^(MPCapableSYNACKRX|MPCapableFallbackSYNACK|MPJoinSynAckRx)=" <<<"$out" | tr '\n' ' ')"
    grep -q "^MPCapableSYNACKRX=1" <<<"$out" && grep -qE "^MPJoinSynAckRx=[1-9]" <<<"$out"
}

run_block() {
    local proto="$1" sc="$2" round="$3"
    as_user python3 "$ROOT/client/$proto/run_experiment.py" -n "$REPS" -f "$FILES" -t "$TIMEOUT" -p 1 \
        --scenario "$sc" --label "campaign=$STAMP round=$round" --seed "$round" --out "$C/$proto" \
        >>"$C/$proto.out" 2>&1
}

declare -A LAST
log "campaign start: until $(date -d "@$DEADLINE" '+%F %T'), paths ${PATH_DEVS[*]}, ALT_PATHS=$ALT_PATHS," \
    "files $FILES x$REPS, scenarios $SCENARIOS, protos $PROTOS, timeout ${TIMEOUT}s"
round=0
stop=0
while [ "$stop" = "0" ]; do
    now="$(date +%s)"
    [ "$now" -ge "$DEADLINE" ] && break
    "$ROOT/client/net_scenario.sh" clear "${PATH_DEVS[@]}" >/dev/null 2>&1
    ensure_routing

    down=()
    for dev in "${PATH_DEVS[@]}"; do path_ok "$dev" || down+=("$dev"); done
    if [ "${#down[@]}" -gt 0 ]; then
        log "waiting: ${down[*]} cannot reach $SERVER_IP; next check in ${POLL}s"
        sleep "$(( POLL < DEADLINE - now ? POLL : DEADLINE - now ))"
        continue
    fi

    protos=()
    for p in ${PROTOS//,/ }; do
        case "$p" in
            mpquic)
                if ! smoke_mpquic; then
                    log "waiting: MPQUIC smoke test did not use two paths; next check in ${POLL}s"
                    sleep "$(( POLL < DEADLINE - now ? POLL : DEADLINE - now ))"
                    continue 2
                fi ;;
            mptcp)
                if ! mptcp_ok; then log "mptcp skipped this round: tcp/$MPTCP_PORT unreachable"; continue; fi
                ensure_endpoints
                if ! smoke_mptcp; then log "mptcp skipped this round: smoke test failed"; continue; fi ;;
        esac
        protos+=("$p")
    done
    [ "${#protos[@]}" -gt 0 ] || { sleep "$POLL"; continue; }

    round=$((round + 1))
    log "round $round: protos ${protos[*]}"
    mapfile -t sc_order < <(tr ',' '\n' <<<"$SCENARIOS" | shuf)
    for sc in "${sc_order[@]}"; do
        mapfile -t p_order < <(printf '%s\n' "${protos[@]}" | shuf)
        for p in "${p_order[@]}"; do
            est="${LAST[$sc/$p]:-900}"
            if [ $(( $(date +%s) + est )) -gt "$DEADLINE" ]; then
                log "deadline: not starting $sc/$p (estimated ${est}s)"
                stop=1; break 2
            fi
            "$ROOT/client/net_scenario.sh" "$sc" "${PATH_DEVS[@]}" >>"$LOG" 2>&1
            t0="$(date +%s)"
            run_block "$p" "$sc" "$round"; rc=$?
            dur=$(( $(date +%s) - t0 ))
            LAST[$sc/$p]="$dur"
            "$ROOT/client/net_scenario.sh" clear "${PATH_DEVS[@]}" >/dev/null 2>&1
            log "round $round $sc/$p: rc=$rc ${dur}s"
        done
    done
done

sudo -u "$RUN_USER" bash -c "python3 '$ROOT/analysis/analyze.py' '$C'/*/*/runs.csv > '$C/summary.txt' 2>&1" \
    && log "summary: $C/summary.txt" || log "no data to summarise"
