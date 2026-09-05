#!/usr/bin/env bash
set -uo pipefail

DATA_DIR="${MULLVAD_DATA_DIR:-$HOME/.local/share/mullvad-status}"
CONF_FILE="$DATA_DIR/mullvad.conf"
UNIT_DIR="${MULLVAD_UNIT_DIR:-/etc/systemd/system}"
INNER_WIDTH=53
MODE="once"

mkdir -p "$DATA_DIR"

write_default_conf() {
    cat > "$CONF_FILE" <<'CONF'
# mullvad.conf - settings for mullvad-status
# This file is sourced as bash, so it must stay valid shell syntax.
# Edit values below, then just re-run mullvad-status -- no restart
# of anything else needed, it's read fresh on every invocation.
#
# EDIT ALL OF THIS to match your own setup before relying on --rotate
# or --heal -- the defaults below are just generic placeholders.

# Name of the gluetun container running the Mullvad WireGuard tunnel
# (the actual container name, e.g. from `docker ps`, not the compose
# service name -- those can differ).
CONTAINER="gluetun"

# How often (seconds) --monitor mode re-checks by default.
# Override per-run with --interval=N.
CHECK_INTERVAL=60

# Where the history log of exit servers is kept.
DB_FILE="$DATA_DIR/history.db"

# Optional: name of a second container that shares gluetun's network
# namespace (network_mode: "service:gluetun") and therefore needs
# restarting alongside it whenever --heal restarts the tunnel. Leave
# blank if you don't have one -- --heal will just restart CONTAINER
# by itself in that case.
APP_CONTAINER=""

# --- Settings used only by --rotate ---

# Directory containing the docker-compose.yml and env file for your
# gluetun stack.
COMPOSE_DIR="$HOME/gluetun"

# Name of the env file (inside COMPOSE_DIR) whose SERVER_COUNTRIES
# line gets updated on each rotation.
ENV_FILE_NAME=".env"

# Space-separated compose SERVICE names (as they appear in
# docker-compose.yml, not container names) to force-recreate on each
# rotation. Usually just your VPN service; add a second name if you
# have a paired app service sharing its network, e.g. "gluetun app".
ROTATE_SERVICES="gluetun"

# File that tracks which country was used last, so rotation advances
# round-robin through the list below instead of repeating.
STATE_FILE="$DATA_DIR/country-index"

# Countries to round-robin through on each --rotate call. Must be
# exact country names/abbreviations your VPN provider's gluetun
# integration accepts for its SERVER_COUNTRIES filter. This example
# list is almost certainly wrong for your subscription -- replace it.
COUNTRIES=("Netherlands" "Sweden" "USA")
CONF
}

# Built-in fallback defaults, used only if mullvad.conf doesn't exist yet
# (in which case it's generated below) or is missing a value.
CONTAINER="gluetun"
CHECK_INTERVAL=60
DB_FILE="$DATA_DIR/history.db"
APP_CONTAINER=""
COMPOSE_DIR="$HOME/gluetun"
ENV_FILE_NAME=".env"
ROTATE_SERVICES="gluetun"
STATE_FILE="$DATA_DIR/country-index"
COUNTRIES=("Netherlands" "Sweden" "USA")

if [[ ! -f "$CONF_FILE" ]]; then
    write_default_conf
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

# --- DB format (pipe-delimited, one line per successful check): ---
# iso_timestamp|exit_server|ip|city|country|status
# Only successful checks (where we got a real exit-server hostname) are
# logged, so the per-server table below stays clean.

print_help() {
    cat <<HELP
mullvad-status - check a gluetun container's Mullvad tunnel status

USAGE:
    mullvad-status [OPTIONS]

DEFAULT BEHAVIOR (no options):
    Runs a single check, logs the result if a valid exit server was
    found, prints the status panel once, and exits.

OPTIONS:
    --monitor          Live dashboard mode: re-checks every interval
                        (default 60s), redraws the panel each second
                        with a live countdown to the next check.
                        Ctrl+C to stop.

    --interval=N        Set the check interval in seconds for --monitor
                        mode. Default: 60. Ignored in default (one-shot)
                        mode.

    --once              Explicit alias for the default one-shot behavior.
                        Kept for compatibility with scripts that already
                        call this flag (e.g. mullvad-discovery).

    --rotate            Rotate to the next country in COUNTRIES (see
                        CONFIG FILE below), update the env file, and
                        recreate the compose services in ROTATE_SERVICES.
                        Prints two log lines and exits -- does not
                        check/log to the history DB itself (run with no
                        options afterward, or use mullvad-discovery, to
                        do that).

    --heal              Check CONTAINER's Docker health status; if
                        unhealthy, restart CONTAINER, then APP_CONTAINER
                        too if one is set, and exit. Does nothing if
                        already healthy. Meant to be run periodically
                        (see --service below).

    --service=ACTION    Manage the systemd timers that run --rotate and
                        --heal on a schedule. ACTION is one of:
                          install   create + enable both timers
                          disable   stop + disable both timers (unit
                                    files are left on disk)
                          remove    stop, disable, and delete both
                                    timers and their service units
                        Requires sudo. Installs: mullvad-rotate.timer
                        (daily, +/-1h) and mullvad-healthwatch.timer
                        (every minute).

    -h, --help          Show this help and exit.

CONFIG FILE:
    All settings (container name, check interval, history DB path, and
    everything --rotate needs) live in:
        $DATA_DIR/mullvad.conf
    It's created automatically with defaults on first run if missing.
    Edit it directly to change settings -- no flags needed for most of
    this, and no restart of anything else required.

ENVIRONMENT:
    MULLVAD_DATA_DIR    Override where mullvad.conf and history.db live.
                         Default: $HOME/.local/share/mullvad-status

EXAMPLES:
    mullvad-status                  # single check, print, exit
    mullvad-status --monitor        # live dashboard, 60s interval
    mullvad-status --monitor --interval=30
    mullvad-status --rotate         # rotate to the next country
    mullvad-status --heal           # restart tunnel if unhealthy
    mullvad-status --service=install    # set up scheduled rotate+heal
    mullvad-status --service=remove     # tear it back down
HELP
}

SERVICE_ACTION=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
        --monitor) MODE="monitor" ;;
        --once) MODE="once" ;;
        --rotate) MODE="rotate" ;;
        --heal) MODE="heal" ;;
        --service=*) MODE="service"; SERVICE_ACTION="${arg#--service=}" ;;
        --interval=*) CHECK_INTERVAL="${arg#--interval=}" ;;
        *)
            echo "Unknown option: $arg" >&2
            echo >&2
            print_help >&2
            exit 1
            ;;
    esac
done

# Build color codes at runtime via printf -v (POSIX-guaranteed escape
# handling in the format string). Keeps the file itself plain ASCII.
printf -v RESET  '\033[0m'
printf -v BOLD   '\033[1m'
printf -v GREEN  '\033[0;32m'
printf -v RED    '\033[0;31m'
printf -v YELLOW '\033[0;33m'
printf -v CYAN   '\033[0;36m'
printf -v DIM    '\033[2m'
# Cursor-home + clear-screen, built the same way as the color codes so
# --monitor's once-per-second redraw doesn't spawn an external `clear`
# process on every tick.
printf -v CLEAR_SCREEN '\033[H\033[2J\033[3J'

ensure_db() {
    mkdir -p "$(dirname "$DB_FILE")"
    touch "$DB_FILE"
}

do_rotate() {
    local last next country env_path

    if [[ "${#COUNTRIES[@]}" -eq 0 ]]; then
        printf "%s[X] COUNTRIES is empty in %s -- add at least one country%s\n" "$RED" "$CONF_FILE" "$RESET"
        return 1
    fi

    last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    next=$(( last % ${#COUNTRIES[@]} ))
    echo "$(( (next + 1) % ${#COUNTRIES[@]} ))" > "$STATE_FILE"
    country="${COUNTRIES[$next]}"

    echo "$(date -Iseconds) rotating to SERVER_COUNTRIES=$country"

    env_path="$COMPOSE_DIR/$ENV_FILE_NAME"
    if [[ ! -f "$env_path" ]]; then
        printf "%s[X] env file not found: %s%s\n" "$RED" "$env_path" "$RESET"
        return 1
    fi

    if grep -q '^SERVER_COUNTRIES=' "$env_path"; then
        sed -i "s/^SERVER_COUNTRIES=.*/SERVER_COUNTRIES=${country}/" "$env_path"
    else
        echo "SERVER_COUNTRIES=${country}" >> "$env_path"
    fi

    # ROTATE_SERVICES is intentionally unquoted -- word-splits into one
    # or more compose service names.
    if ! (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate $ROTATE_SERVICES); then
        printf "%s[X] docker compose failed during rotation%s\n" "$RED" "$RESET"
        return 1
    fi

    echo "$(date -Iseconds) rotation complete, now on $country"
}

do_heal() {
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)

    if [[ "$status" == "unhealthy" ]]; then
        if [[ -n "$APP_CONTAINER" ]]; then
            echo "$(date -Iseconds) $CONTAINER is unhealthy -- restarting $CONTAINER and $APP_CONTAINER together"
            docker restart "$CONTAINER"
            sleep 10
            docker restart "$APP_CONTAINER"
        else
            echo "$(date -Iseconds) $CONTAINER is unhealthy -- restarting it"
            docker restart "$CONTAINER"
        fi
        echo "$(date -Iseconds) restart complete"
    elif [[ -z "$status" ]]; then
        printf "%s%s WARNING: could not inspect %s -- is it running?%s\n" "$YELLOW" "$(date -Iseconds)" "$CONTAINER" "$RESET"
        return 1
    fi
    # healthy: do nothing, exit quietly (this runs every minute via
    # --service install, no need to print anything when there's nothing
    # to fix)
}

SERVICE_UNITS=(
    "mullvad-rotate.service"
    "mullvad-rotate.timer"
    "mullvad-healthwatch.service"
    "mullvad-healthwatch.timer"
)

require_systemctl() {
    if ! command -v systemctl >/dev/null 2>&1; then
        printf "%s[X] systemctl not found -- --service requires a systemd-based host%s\n" "$RED" "$RESET"
        exit 1
    fi
}

do_service_install() {
    local script_path this_user
    script_path=$(readlink -f "$0")
    this_user=$(whoami)

    sudo tee "$UNIT_DIR/mullvad-rotate.service" >/dev/null <<UNIT
[Unit]
Description=Rotate Mullvad country for the gluetun tunnel ($CONTAINER)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$script_path --rotate
User=$this_user
UNIT

    sudo tee "$UNIT_DIR/mullvad-rotate.timer" >/dev/null <<'UNIT'
[Unit]
Description=Periodically rotate Mullvad country

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
AccuracySec=10min

[Install]
WantedBy=timers.target
UNIT

    sudo tee "$UNIT_DIR/mullvad-healthwatch.service" >/dev/null <<UNIT
[Unit]
Description=Restart $CONTAINER (and APP_CONTAINER if set) when the Mullvad tunnel is unhealthy
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$script_path --heal
User=$this_user
UNIT

    sudo tee "$UNIT_DIR/mullvad-healthwatch.timer" >/dev/null <<'UNIT'
[Unit]
Description=Check Mullvad tunnel health every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable --now mullvad-rotate.timer
    sudo systemctl enable --now mullvad-healthwatch.timer

    printf "%s[OK] Installed and enabled mullvad-rotate.timer and mullvad-healthwatch.timer%s\n" "$GREEN" "$RESET"
}

do_service_disable() {
    sudo systemctl disable --now mullvad-rotate.timer 2>/dev/null
    sudo systemctl disable --now mullvad-healthwatch.timer 2>/dev/null
    printf "%s[OK] Disabled mullvad-rotate.timer and mullvad-healthwatch.timer (unit files kept on disk)%s\n" "$YELLOW" "$RESET"
}

do_service_remove() {
    sudo systemctl disable --now mullvad-rotate.timer 2>/dev/null
    sudo systemctl disable --now mullvad-healthwatch.timer 2>/dev/null
    local unit
    for unit in "${SERVICE_UNITS[@]}"; do
        sudo rm -f "$UNIT_DIR/$unit"
    done
    sudo systemctl daemon-reload
    printf "%s[OK] Removed all mullvad-status systemd units%s\n" "$RED" "$RESET"
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.2fGB", b/1073741824;
        else if (b >= 1048576) printf "%.2fMB", b/1048576;
        else if (b >= 1024) printf "%.2fKB", b/1024;
        else printf "%dB", b;
    }'
}

border() {
    local char="$1"
    printf "%s+" "$CYAN"
    printf '%*s' "$INNER_WIDTH" '' | tr ' ' "$char"
    printf "+%s\n" "$RESET"
}

box_top()    { border "-"; }
box_line()   { border "-"; }
box_bottom() { border "-"; }

content_line() {
    local text="$1"
    local color="${2:-}"
    local padded
    padded=$(printf "%-${INNER_WIDTH}.${INNER_WIDTH}s" "$text")
    printf "%s|%s%s%s%s%s|%s\n" "$CYAN" "$RESET" "$color" "$padded" "$RESET" "$CYAN" "$RESET"
}

row() {
    local label="$1"
    local value="$2"
    local color="${3:-}"
    content_line " $(printf '%-14s' "$label") ${value}" "$color"
}

do_check() {
    JSON=$(docker exec "$CONTAINER" sh -c "wget -qO- https://am.i.mullvad.net/json" 2>/dev/null)
    CONNECTED_TEXT=""
    if [[ -z "$JSON" ]]; then
        CONNECTED_TEXT=$(docker exec "$CONTAINER" sh -c "wget -qO- https://am.i.mullvad.net/connected" 2>/dev/null)
    fi
    LOG_LINE=$(docker logs --tail 50 "$CONTAINER" 2>&1 | grep -i "public ip" | tail -1)

    # Real leak-check: count of packets/bytes actually routed out through
    # the tun0 tunnel interface, independent of any external API response.
    local iptables_line
    iptables_line=$(docker exec "$CONTAINER" iptables -L OUTPUT -n -v 2>/dev/null | grep -E '\btun0\b' | head -1)
    TUN_PKTS=$(echo "$iptables_line" | awk '{print $1}')
    TUN_BYTES=$(echo "$iptables_line" | awk '{print $2}')

    MULLVAD_EXIT="" IP="" CITY="" COUNTRY="" HOSTNAME=""
    if [[ -n "$JSON" ]]; then
        MULLVAD_EXIT=$(echo "$JSON" | grep -o '"mullvad_exit_ip":[a-z]*' | cut -d: -f2)
        IP=$(echo "$JSON" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)
        CITY=$(echo "$JSON" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        COUNTRY=$(echo "$JSON" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        HOSTNAME=$(echo "$JSON" | grep -o '"mullvad_exit_ip_hostname":"[^"]*"' | cut -d'"' -f4)

        if [[ "$MULLVAD_EXIT" == "true" && -n "$HOSTNAME" ]]; then
            ensure_db
            local last_server=""
            if [[ -s "$DB_FILE" ]]; then
                last_server=$(tail -1 "$DB_FILE" | cut -d'|' -f2)
            fi
            if [[ "$HOSTNAME" != "$last_server" ]]; then
                printf "%s|%s|%s|%s|%s|UP\n" "$(date -Iseconds)" "$HOSTNAME" "$IP" "$CITY" "$COUNTRY" >> "$DB_FILE"
            fi
        fi
    fi

    LAST_RUN_TS=$(date +%H:%M:%S)
}

server_table_rows() {
    [[ -f "$DB_FILE" ]] || return
    awk -F'|' '
        {
            server=$2; ts=$1; loc=$4", "$5
            count[server]++
            last[server]=ts
            lastloc[server]=loc
        }
        END {
            for (s in count) printf "%s|%s|%s|%d\n", s, last[s], lastloc[s], count[s]
        }
    ' "$DB_FILE" | sort -t'|' -k2,2r
}

render() {
    printf '%s' "$CLEAR_SCREEN"
    echo
    box_top
    content_line " Mullvad Tunnel Status - ${CONTAINER}" "$BOLD"
    box_line

    if [[ -n "${JSON:-}" ]]; then
        if [[ "$MULLVAD_EXIT" == "true" ]]; then
            row " Status:" "[UP] CONNECTED" "$GREEN"
        else
            row " Status:" "[X] NOT CONNECTED" "$RED"
        fi
        row " Public IP:" "${IP:-unknown}"
        row " Location:" "${CITY:-?}, ${COUNTRY:-?}"
        row " Exit server:" "${HOSTNAME:-unknown}"
        if [[ -n "${TUN_PKTS:-}" ]]; then
            row " Tunnel traffic:" "$(printf '%s pkts / %s' "$TUN_PKTS" "$(human_bytes "${TUN_BYTES:-0}")")"
        fi
    elif [[ -n "${CONNECTED_TEXT:-}" ]]; then
        row " Status:" "(fallback check)" "$YELLOW"
        content_line " ${CONNECTED_TEXT}"
    else
        row " Status:" "[X] UNREACHABLE" "$RED"
    fi

    box_line
    content_line " Known exit servers:" "$BOLD"
    content_line "$(printf '%-2s%-16s %-18s %3s  %-8s' '' 'SERVER' 'LOCATION' 'CNT' 'LAST')"

    local any=0
    while IFS='|' read -r server ts loc count; do
        [[ -z "$server" ]] && continue
        any=1
        local hh
        hh=$(date -d "$ts" +%H:%M:%S 2>/dev/null || echo "$ts")
        local marker="  " color=""
        if [[ "$server" == "${HOSTNAME:-__none__}" ]]; then
            marker="> "
            color="$GREEN"
        fi
        content_line "$(printf "%s%-16.16s %-18.18s %3s  %-8.8s" "$marker" "$server" "$loc" "$count" "$hh")" "$color"
    done < <(server_table_rows)

    if [[ "$any" -eq 0 ]]; then
        content_line "  (no history yet)" "$DIM"
    fi

    box_line

    if [[ -n "${LOG_LINE:-}" ]]; then
        CLEAN_LOG=$(echo "$LOG_LINE" | sed -E 's/^.*msg="//; s/"$//')
        content_line " Last log:" "$DIM"
        echo "$CLEAN_LOG" | fold -s -w $((INNER_WIDTH - 1)) | while IFS= read -r line; do
            content_line " ${line}" "$DIM"
        done
    fi

    box_line
    if [[ "$MODE" == "once" ]]; then
        content_line " Last run: ${LAST_RUN_TS}" "$DIM"
    else
        local mm ss
        mm=$((SECONDS_LEFT / 60))
        ss=$((SECONDS_LEFT % 60))
        content_line "$(printf " Last run: %-12s  Next check in: %02d:%02d" "$LAST_RUN_TS" "$mm" "$ss")" "$DIM"
    fi
    box_bottom
    echo
}

if [[ "$MODE" == "rotate" ]]; then
    do_rotate
    exit $?
fi

if [[ "$MODE" == "heal" ]]; then
    do_heal
    exit $?
fi

if [[ "$MODE" == "service" ]]; then
    require_systemctl
    case "$SERVICE_ACTION" in
        install) do_service_install ;;
        disable) do_service_disable ;;
        remove)  do_service_remove ;;
        *)
            printf "%s[X] --service requires install, disable, or remove (got: '%s')%s\n" "$RED" "$SERVICE_ACTION" "$RESET"
            exit 1
            ;;
    esac
    exit $?
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    printf "%s[X] Container '%s' not found.%s\n" "$RED" "$CONTAINER" "$RESET"
    exit 1
fi

if [[ "$MODE" == "once" ]]; then
    do_check
    render
    exit 0
fi

# --- --monitor mode from here on ---
trap 'echo; echo "Stopped monitoring."; exit 0' INT TERM

do_check
SECONDS_LEFT="$CHECK_INTERVAL"
render

while true; do
    sleep 1
    SECONDS_LEFT=$((SECONDS_LEFT - 1))
    if [[ "$SECONDS_LEFT" -le 0 ]]; then
        do_check
        SECONDS_LEFT="$CHECK_INTERVAL"
    fi
    render
done
