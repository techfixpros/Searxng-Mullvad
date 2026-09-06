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
COUNTRIES=("Netherlands" "Germany" "Sweden" "USA" "UK" "Canada")
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
COUNTRIES=("Netherlands" "Germany" "Sweden" "USA" "UK" "Canada")

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

    --select            Interactive tiered menu: pick "All Countries"
                        (uses the full COUNTRIES list), a known country
                        directly, or drill into "Single Exit" to pick
                        one exact server from a specific country.
                        Updates SERVER_COUNTRIES or SERVER_HOSTNAMES in
                        the env file accordingly (clearing whichever
                        one doesn't apply) and recreates the tunnel.
                        Arrow keys to navigate, Enter to confirm,
                        ".. Back" or q to go back/cancel. Requires a
                        terminal -- not for cron/timers.

    --heal              Check CONTAINER's Docker health status; if
                        unhealthy, restart CONTAINER, then APP_CONTAINER
                        too if one is set, and exit. Does nothing if
                        already healthy. Meant to be run periodically
                        (see --service below).

    --verbose           One-shot wide dashboard: the normal status
                        panel plus every known exit server (no 20-row
                        cap), the scheduled-service install/active
                        state for both timers, and the raw contents of
                        the env file (WIREGUARD_PRIVATE_KEY redacted)
                        and mullvad.conf. Wider than the normal panel
                        to fit all of this without truncating.

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

    --activate          Enable mullvad-rotate.timer specifically (just
                        this one timer, not healthwatch). Requires it
                        to already be installed (see --service=install).
                        A quick on/off switch for scheduled rotation --
                        use --service=disable/remove instead if you
                        want to tear down both timers together.

    --disable           Disable mullvad-rotate.timer specifically (just
                        this one timer, not healthwatch). Leaves the
                        unit file in place -- use --activate to turn it
                        back on later.

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
    mullvad-status --select         # pick a specific known server
    mullvad-status --heal           # restart tunnel if unhealthy
    mullvad-status --verbose        # wide one-shot dashboard, everything
    mullvad-status --activate       # turn on scheduled rotation
    mullvad-status --disable        # turn off scheduled rotation
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
        --select) MODE="select" ;;
        --heal) MODE="heal" ;;
        --verbose) MODE="verbose" ;;
        --activate) MODE="activate" ;;
        --disable) MODE="disable_timer" ;;
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

set_env_line() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

remove_env_line() {
    local file="$1" key="$2"
    sed -i "/^${key}=/d" "$file"
}

# Rewrites (or appends) the COUNTRIES=(...) line in CONF_FILE to
# exactly the country names passed in. Used by --select's post-pick
# timer prompt to scope --rotate to whatever was just chosen, instead
# of leaving it cycling through the full original list. Uses awk
# rather than sed for the replacement to sidestep quoting/escaping
# issues with the parentheses and quotes in the array literal.
set_conf_countries() {
    local -a new_countries=("$@")
    local joined line
    joined=$(printf '"%s" ' "${new_countries[@]}")
    joined="${joined% }"
    line="COUNTRIES=(${joined})"

    if grep -q '^COUNTRIES=' "$CONF_FILE"; then
        local tmp
        tmp=$(mktemp)
        awk -v newline="$line" '
            /^COUNTRIES=/ { print newline; next }
            { print }
        ' "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"
    else
        echo "$line" >> "$CONF_FILE"
    fi
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

    # A specific-server pin (from --select) and a country filter can
    # conflict if the pinned server isn't in that country -- clear any
    # pin so country rotation always has a clean slate to work with.
    remove_env_line "$env_path" "SERVER_HOSTNAMES"
    set_env_line "$env_path" "SERVER_COUNTRIES" "$country"

    # ROTATE_SERVICES is intentionally unquoted -- word-splits into one
    # or more compose service names.
    if ! (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate $ROTATE_SERVICES); then
        printf "%s[X] docker compose failed during rotation%s\n" "$RED" "$RESET"
        return 1
    fi

    echo "$(date -Iseconds) rotation complete, now on $country"
}

# Generic single-level radio-button menu. Draws items_ref (a nameref to
# an array of already-formatted label strings) with arrow-key
# navigation, in place, no flicker.
#
# Args: $1 = nameref to items array, $2 = "1" to append a ".. Back"
# entry (for submenus) or "0" (for the root level, where q/Ctrl+C is
# the only way out).
#
# Sets on return:
#   MENU_CANCELLED=1   if the user pressed q or Ctrl+C
#   MENU_WENT_BACK=1   if they picked ".. Back"
#   MENU_CHOICE_INDEX  the chosen index into items_ref (0-based),
#                      valid only if neither of the above is 1
radio_menu() {
    local -n items_ref=$1
    local allow_back="$2"

    local -a display_items=("${items_ref[@]}")
    [[ "$allow_back" == "1" ]] && display_items+=(".. Back")

    local n="${#display_items[@]}"
    local cursor=0 lines_printed=0
    MENU_CANCELLED=0
    MENU_WENT_BACK=0

    draw_radio_menu() {
        local j
        if [[ "$lines_printed" -gt 0 ]]; then
            printf '\033[%dA' "$lines_printed"
        fi
        lines_printed=0
        for (( j=0; j<n; j++ )); do
            if [[ "$j" == "$cursor" ]]; then
                printf '\033[K  %s(*)%s %s\n' "$GREEN" "$RESET" "${display_items[$j]}"
            else
                printf '\033[K  ( ) %s\n' "${display_items[$j]}"
            fi
            lines_printed=$(( lines_printed + 1 ))
        done
    }

    printf '\033[?25l'
    draw_radio_menu

    local key
    while true; do
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key
            case "$key" in
                '[A') cursor=$(( (cursor - 1 + n) % n )) ;;
                '[B') cursor=$(( (cursor + 1) % n )) ;;
            esac
            draw_radio_menu
        elif [[ -z "$key" ]]; then
            break
        elif [[ "$key" == "q" ]]; then
            printf '\033[?25h'
            MENU_CANCELLED=1
            return 1
        fi
    done
    printf '\033[?25h'

    if [[ "$allow_back" == "1" && "$cursor" -eq "$(( n - 1 ))" ]]; then
        MENU_WENT_BACK=1
        return 0
    fi

    MENU_CHOICE_INDEX="$cursor"
    return 0
}

do_select() {
    local env_path="$COMPOSE_DIR/$ENV_FILE_NAME"

    if [[ ! -t 0 ]]; then
        printf "%s[X] --select requires an interactive terminal%s\n" "$RED" "$RESET"
        return 1
    fi

    if [[ ! -f "$env_path" ]]; then
        printf "%s[X] env file not found: %s%s\n" "$RED" "$env_path" "$RESET"
        return 1
    fi

    if [[ ! -s "$DB_FILE" ]]; then
        printf "%s[X] No known exit servers yet in %s -- run mullvad-status at least once first%s\n" "$RED" "$DB_FILE" "$RESET"
        return 1
    fi

    local -a known_countries=()
    local c
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        known_countries+=("$(transliterate "$c")")
    done < <(cut -d'|' -f5 "$DB_FILE" | sort -u)

    if [[ "${#known_countries[@]}" -eq 0 ]]; then
        printf "%s[X] No known exit servers found%s\n" "$RED" "$RESET"
        return 1
    fi

    local result_mode="" result_value="" result_is_all_countries=0

    while true; do
        local -a root_items=("All Countries")
        for c in "${known_countries[@]}"; do
            root_items+=("$c")
        done
        local single_exit_index="${#root_items[@]}"
        root_items+=("Single Exit >")

        echo "Select a rotation mode:"
        echo
        radio_menu root_items 0

        if [[ "$MENU_CANCELLED" -eq 1 ]]; then
            echo
            echo "Cancelled."
            return 1
        fi

        if [[ "$MENU_CHOICE_INDEX" -eq 0 ]]; then
            local joined
            joined=$(IFS=,; echo "${COUNTRIES[*]}")
            result_mode="countries"
            result_value="$joined"
            result_is_all_countries=1
            break
        elif [[ "$MENU_CHOICE_INDEX" -eq "$single_exit_index" ]]; then
            # --- Single Exit: country submenu, then server submenu ---
            local went_back_to_root=0
            while true; do
                echo
                echo "Single Exit -- choose a country:"
                echo
                radio_menu known_countries 1

                if [[ "$MENU_CANCELLED" -eq 1 ]]; then
                    echo
                    echo "Cancelled."
                    return 1
                fi
                if [[ "$MENU_WENT_BACK" -eq 1 ]]; then
                    went_back_to_root=1
                    break
                fi

                local chosen_country="${known_countries[$MENU_CHOICE_INDEX]}"

                local -a srv_servers=() srv_display=()
                local server ts city count hh
                while IFS='|' read -r server ts city count; do
                    [[ -z "$server" ]] && continue
                    hh=$(date -d "$ts" +%H:%M:%S 2>/dev/null || echo "$ts")
                    srv_display+=("$(printf "%-18s %-16s %3sx  %s" "$server" "$(transliterate "$city")" "$count" "$hh")")
                    srv_servers+=("$server")
                done < <(awk -F'|' -v want="$chosen_country" '
                    { server=$2; ts=$1; city=$4; country=$5
                      if (country != want) next
                      count[server]++; last[server]=ts; lastcity[server]=city }
                    END { for (s in count) printf "%s|%s|%s|%d\n", s, last[s], lastcity[s], count[s] }
                ' "$DB_FILE" | sort -t'|' -k2,2r)

                echo
                echo "Servers in $chosen_country:"
                echo
                radio_menu srv_display 1

                if [[ "$MENU_CANCELLED" -eq 1 ]]; then
                    echo
                    echo "Cancelled."
                    return 1
                fi
                if [[ "$MENU_WENT_BACK" -eq 1 ]]; then
                    continue
                fi

                result_mode="hostname"
                result_value="${srv_servers[$MENU_CHOICE_INDEX]}"
                break 2
            done
            [[ "$went_back_to_root" -eq 1 ]] && continue
        else
            result_mode="countries"
            result_value="${known_countries[$(( MENU_CHOICE_INDEX - 1 ))]}"
            break
        fi
    done

    echo
    if [[ "$result_mode" == "hostname" ]]; then
        echo "$(date -Iseconds) pinning to exit server $result_value"
        set_env_line "$env_path" "SERVER_HOSTNAMES" "$result_value"
        remove_env_line "$env_path" "SERVER_COUNTRIES"
    else
        echo "$(date -Iseconds) setting SERVER_COUNTRIES=$result_value"
        remove_env_line "$env_path" "SERVER_HOSTNAMES"
        set_env_line "$env_path" "SERVER_COUNTRIES" "$result_value"
    fi

    if ! (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate $ROTATE_SERVICES); then
        printf "%s[X] docker compose failed while switching servers%s\n" "$RED" "$RESET"
        return 1
    fi

    echo "$(date -Iseconds) done"

    # State-driven check, but the install/enable branches are skipped
    # for a specific-exit pin (result_mode == "hostname") -- turning
    # rotation on would immediately threaten to rotate away from the
    # exact server just pinned, defeating the point of pinning it.
    # The disable-if-active branch still applies to every selection
    # type, since an already-active timer threatens any of them.
    # Relies on result_mode/result_value/result_is_all_countries from
    # the enclosing do_select() scope -- only ever called synchronously
    # from within it, so bash's dynamic scoping makes them visible here
    # without needing to pass them explicitly.
    offer_scope_countries() {
        local scope_desc
        if [[ "$result_is_all_countries" -eq 1 ]]; then
            scope_desc="the full country list"
        else
            scope_desc="$result_value"
        fi
        echo
        if confirm "Update COUNTRIES in $CONF_FILE to scope rotation to $scope_desc?"; then
            if [[ "$result_is_all_countries" -eq 1 ]]; then
                set_conf_countries "${COUNTRIES[@]}"
            else
                set_conf_countries "$result_value"
            fi
            printf "%s[OK] Updated COUNTRIES in %s%s\n" "$GREEN" "$CONF_FILE" "$RESET"
        fi
    }

    local timer_status
    timer_status=$(rotate_timer_status)
    case "$timer_status" in
        not_installed)
            if [[ "$result_mode" != "hostname" ]]; then
                echo
                if confirm "mullvad-rotate.timer isn't installed. Install and enable scheduled rotation (this also installs mullvad-healthwatch.timer)?"; then
                    do_service_install
                    offer_scope_countries
                fi
            fi
            ;;
        inactive)
            if [[ "$result_mode" != "hostname" ]]; then
                echo
                if confirm "mullvad-rotate.timer is installed but not active. Enable it now?"; then
                    sudo systemctl enable --now mullvad-rotate.timer
                    printf "%s[OK] mullvad-rotate.timer enabled%s\n" "$GREEN" "$RESET"
                    offer_scope_countries
                fi
            fi
            ;;
        active)
            echo
            if confirm "mullvad-rotate.timer is active and may override this choice next time it fires. Disable it so it holds?"; then
                sudo systemctl disable --now mullvad-rotate.timer
                printf "%s[OK] mullvad-rotate.timer disabled%s\n" "$GREEN" "$RESET"
            else
                printf "%sNote: this may be overridden the next time mullvad-rotate.timer fires.%s\n" "$YELLOW" "$RESET"
            fi
            ;;
        unavailable)
            : # systemctl not present at all -- nothing to offer
            ;;
    esac
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

# Reports "not_installed", "active", "inactive", or "unavailable"
# (systemctl not present at all) for the given systemd unit name.
# Prints nothing; caller checks the echoed value. Never exits the
# script -- this is an optional, best-effort check that should
# degrade silently rather than error out.
timer_status_of() {
    local unit="$1"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "unavailable"
        return
    fi
    if [[ ! -f "$UNIT_DIR/$unit" ]]; then
        echo "not_installed"
    elif systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

# Kept as a thin wrapper -- used by --select to warn about (or offer
# to fix) interactions between a manual pick and scheduled rotation.
rotate_timer_status() {
    timer_status_of "mullvad-rotate.timer"
}

# Human-readable text for a timer_status_of()/rotate_timer_status()
# value, used in --verbose's services section.
describe_timer_status() {
    case "$1" in
        active)        echo "installed, active" ;;
        inactive)      echo "installed, inactive" ;;
        not_installed) echo "not installed" ;;
        unavailable)   echo "systemctl unavailable" ;;
        *)             echo "unknown" ;;
    esac
}

do_activate_timer() {
    require_systemctl
    local status
    status=$(timer_status_of "mullvad-rotate.timer")
    case "$status" in
        active)
            printf "%smullvad-rotate.timer is already active%s\n" "$YELLOW" "$RESET"
            ;;
        inactive)
            sudo systemctl enable --now mullvad-rotate.timer
            printf "%s[OK] mullvad-rotate.timer enabled%s\n" "$GREEN" "$RESET"
            ;;
        not_installed)
            printf "%s[X] mullvad-rotate.timer isn't installed -- run --service=install first%s\n" "$RED" "$RESET"
            return 1
            ;;
    esac
}

do_disable_timer() {
    require_systemctl
    local status
    status=$(timer_status_of "mullvad-rotate.timer")
    case "$status" in
        active)
            sudo systemctl disable --now mullvad-rotate.timer
            printf "%s[OK] mullvad-rotate.timer disabled%s\n" "$GREEN" "$RESET"
            ;;
        inactive)
            printf "%smullvad-rotate.timer is already inactive%s\n" "$YELLOW" "$RESET"
            ;;
        not_installed)
            printf "%smullvad-rotate.timer isn't installed -- nothing to disable%s\n" "$YELLOW" "$RESET"
            ;;
    esac
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

# Displays a KEY=VALUE style file (env file or mullvad.conf) with
# comments and blank lines stripped, variable names colored to stand
# out from their values, and any name in expected_ref that's missing
# from the file shown as "<NAME>=UNSET" in a warning color. redact_key
# (optional) has its value replaced with <redacted> rather than shown.
display_config_kv() {
    local path="$1" redact_key="${3:-}"
    local -n expected_ref=$2

    if [[ ! -f "$path" ]]; then
        printf "%s(not found)%s\n" "$RED" "$RESET"
        return
    fi

    local -a found_keys=()
    local line key value

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            found_keys+=("$key")
            if [[ -n "$redact_key" && "$key" == "$redact_key" ]]; then
                printf "%s%s%s=%s<redacted>%s\n" "$CYAN" "$key" "$RESET" "$DIM" "$RESET"
            else
                printf "%s%s%s=%s\n" "$CYAN" "$key" "$RESET" "$value"
            fi
        fi
    done < "$path"

    local exp seen k
    for exp in "${expected_ref[@]}"; do
        seen=0
        for k in "${found_keys[@]}"; do
            if [[ "$k" == "$exp" ]]; then
                seen=1
                break
            fi
        done
        if [[ "$seen" -eq 0 ]]; then
            printf "%s%s=UNSET%s\n" "$YELLOW" "$exp" "$RESET"
        fi
    done
}

do_verbose() {
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        printf "%s[X] Container '%s' not found.%s\n" "$RED" "$CONTAINER" "$RESET"
        return 1
    fi

    do_check

    # Wider box for this mode only -- border()/content_line() read
    # INNER_WIDTH fresh on every call, so just changing it here is
    # enough. Not restored afterward since --verbose always exits
    # right after this function returns.
    INNER_WIDTH=100

    echo
    box_top
    content_line " Mullvad Tunnel Status - ${CONTAINER} (verbose)" "$BOLD"
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
    content_line " All known exit servers:" "$BOLD"
    content_line "$(printf '%-2s%-18s %-30s %5s  %-25s' '' 'SERVER' 'LOCATION' 'CNT' 'LAST SEEN')"

    local any=0 server ts loc count
    while IFS='|' read -r server ts loc count; do
        [[ -z "$server" ]] && continue
        any=1
        loc=$(transliterate "$loc")
        local marker="  " color=""
        if [[ "$server" == "${HOSTNAME:-__none__}" ]]; then
            marker="> "
            color="$GREEN"
        fi
        content_line "$(printf "%s%-18.18s %-30.30s %5s  %-25.25s" "$marker" "$server" "$loc" "$count" "$ts")" "$color"
    done < <(server_table_rows)

    if [[ "$any" -eq 0 ]]; then
        content_line "  (no history yet)" "$DIM"
    fi

    box_line
    if [[ -n "${LOG_LINE:-}" ]]; then
        local clean_log
        clean_log=$(echo "$LOG_LINE" | sed -E 's/^.*msg="//; s/"$//')
        clean_log=$(transliterate "$clean_log")
        content_line " Last log:" "$DIM"
        echo "$clean_log" | fold -s -w $((INNER_WIDTH - 1)) | while IFS= read -r line; do
            content_line " ${line}" "$DIM"
        done
    fi

    box_line
    content_line " Scheduled services:" "$BOLD"
    local rot_status heal_status
    rot_status=$(timer_status_of "mullvad-rotate.timer")
    heal_status=$(timer_status_of "mullvad-healthwatch.timer")
    row "  mullvad-rotate.timer:" "$(describe_timer_status "$rot_status")"
    row "  mullvad-healthwatch.timer:" "$(describe_timer_status "$heal_status")"

    row " Last run:" "$LAST_RUN_TS" "$DIM"
    box_bottom
    echo

    local env_path="$COMPOSE_DIR/$ENV_FILE_NAME"
    local -a env_expected_keys=(WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES SERVER_COUNTRIES SERVER_HOSTNAMES)
    printf "%s--- %s ---%s\n" "$BOLD" "$env_path" "$RESET"
    display_config_kv "$env_path" env_expected_keys "WIREGUARD_PRIVATE_KEY"
    echo

    local -a conf_expected_keys=(CONTAINER CHECK_INTERVAL DB_FILE APP_CONTAINER COMPOSE_DIR ENV_FILE_NAME ROTATE_SERVICES STATE_FILE COUNTRIES)
    printf "%s--- %s ---%s\n" "$BOLD" "$CONF_FILE" "$RESET"
    display_config_kv "$CONF_FILE" conf_expected_keys
    echo
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.2fGB", b/1073741824;
        else if (b >= 1048576) printf "%.2fMB", b/1048576;
        else if (b >= 1024) printf "%.2fKB", b/1024;
        else printf "%dB", b;
    }'
}

# Converts accented/non-ASCII characters (e.g. from city/country names
# like "Malmoe" or "Vaestra Goetaland") to plain ASCII, so fixed-width
# table columns line up regardless of the host's locale -- printf's
# byte-vs-display-width counting for multi-byte UTF-8 characters isn't
# reliable unless the shell locale happens to be UTF-8-aware, which we
# can't assume. Falls back to the original string if iconv is missing
# or fails, rather than erroring out.
transliterate() {
    local input="$1" out
    out=$(printf '%s' "$input" | LC_ALL=C.UTF-8 iconv -f utf8 -t ascii//TRANSLIT 2>/dev/null)
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
    else
        printf '%s' "$input"
    fi
}

# Simple y/N prompt. Returns 0 (true) only on an explicit y/Y answer.
confirm() {
    local prompt="$1" reply
    read -rp "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
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
        CITY=$(transliterate "$CITY")
        COUNTRY=$(transliterate "$COUNTRY")
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

# Same aggregation as server_table_rows(), but keeps city/country
# separate and sorts by country first (then most-recent within each
# country), for --select's grouped menu.
server_rows_by_country() {
    [[ -f "$DB_FILE" ]] || return
    awk -F'|' '
        {
            server=$2; ts=$1; city=$4; country=$5
            count[server]++
            last[server]=ts
            lastcity[server]=city
            lastcountry[server]=country
        }
        END {
            for (s in count) printf "%s|%s|%s|%s|%d\n", lastcountry[s], s, last[s], lastcity[s], count[s]
        }
    ' "$DB_FILE" | sort -t'|' -k1,1 -k3,3r
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

    local any=0 table_limit=20
    local all_server_rows total_server_count=0
    all_server_rows=$(server_table_rows)
    if [[ -n "$all_server_rows" ]]; then
        total_server_count=$(printf '%s\n' "$all_server_rows" | wc -l)
    fi

    while IFS='|' read -r server ts loc count; do
        [[ -z "$server" ]] && continue
        any=1
        local hh
        hh=$(date -d "$ts" +%H:%M:%S 2>/dev/null || echo "$ts")
        loc=$(transliterate "$loc")
        local marker="  " color=""
        if [[ "$server" == "${HOSTNAME:-__none__}" ]]; then
            marker="> "
            color="$GREEN"
        fi
        content_line "$(printf "%s%-16.16s %-18.18s %3s  %-8.8s" "$marker" "$server" "$loc" "$count" "$hh")" "$color"
    done < <(printf '%s\n' "$all_server_rows" | head -n "$table_limit")

    if [[ "$total_server_count" -gt "$table_limit" ]]; then
        local remaining=$(( total_server_count - table_limit ))
        local label="servers"
        [[ "$remaining" -eq 1 ]] && label="server"
        content_line "  + ${remaining} other ${label}" "$DIM"
    fi

    if [[ "$any" -eq 0 ]]; then
        content_line "  (no history yet)" "$DIM"
    fi

    box_line

    if [[ -n "${LOG_LINE:-}" ]]; then
        CLEAN_LOG=$(echo "$LOG_LINE" | sed -E 's/^.*msg="//; s/"$//')
        CLEAN_LOG=$(transliterate "$CLEAN_LOG")
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

if [[ "$MODE" == "select" ]]; then
    do_select
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

if [[ "$MODE" == "verbose" ]]; then
    do_verbose
    exit $?
fi

if [[ "$MODE" == "activate" ]]; then
    do_activate_timer
    exit $?
fi

if [[ "$MODE" == "disable_timer" ]]; then
    do_disable_timer
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