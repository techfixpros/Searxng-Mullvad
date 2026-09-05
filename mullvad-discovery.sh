#!/usr/bin/env bash
set -uo pipefail

# --- Config ---
# CONTAINER and DB_FILE are read from mullvad-status's own config file so
# the two tools always agree on which container/history file to use --
# override MULLVAD_DATA_DIR if you keep that config somewhere nonstandard.
DATA_DIR="${MULLVAD_DATA_DIR:-$HOME/.local/share/mullvad-status}"
CONF_FILE="$DATA_DIR/mullvad.conf"

CONTAINER="gluetun"
DB_FILE="$DATA_DIR/history.db"

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# Settings specific to this tool (not part of mullvad.conf, since they're
# about how discovery itself runs, not the tunnel it's discovering).
STATUS_SCRIPT="${STATUS_SCRIPT:-/usr/local/bin/mullvad-status}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"   # max seconds to wait for gluetun to report healthy
POLL_INTERVAL=2

print_help() {
    cat <<'HELP'
mullvad-discovery - rapidly rotate Mullvad servers to discover exit
servers, logging each one to mullvad-status's history DB.

USAGE:
    mullvad-discovery [COUNT]
    mullvad-discovery --count=N
    mullvad-discovery -h | --help

DEFAULT BEHAVIOR (no arguments):
    Prompts interactively for the number of rotations to run.

ARGUMENTS:
    COUNT               Number of rotations to run (positional, e.g.
                         "mullvad-discovery 10").
    --count=N            Same as above, as a named flag.
    -h, --help           Show this help and exit.

HOW IT WORKS:
    For each rotation: runs "mullvad-status --rotate" to advance to
    the next country and recreate the tunnel containers, polls
    CONTAINER's Docker healthcheck (every 2s, up to HEALTH_TIMEOUT
    seconds) until it reports healthy, then runs the status script in
    one-shot mode to check and log the new exit server. If a rotation
    never becomes healthy within the timeout, it's skipped and the
    loop moves on to the next one. CONTAINER and DB_FILE come from
    mullvad-status's own mullvad.conf, so both tools always agree on
    which container and history file to use.

ENVIRONMENT:
    MULLVAD_DATA_DIR      Where to find mullvad-status's mullvad.conf
                          (for CONTAINER and DB_FILE) and history.db.
                          Default: ~/.local/share/mullvad-status
    STATUS_SCRIPT         Path to mullvad-status. Used both for
                          rotating (--rotate) and checking/logging.
                          Default: /usr/local/bin/mullvad-status
    HEALTH_TIMEOUT         Max seconds to wait per rotation for the
                          tunnel to become healthy. Default: 60.

EXAMPLES:
    mullvad-discovery              # prompts for a count
    mullvad-discovery 10           # run 10 rotations
    mullvad-discovery --count=20   # run 20 rotations
HELP
}

COUNT=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
        --count=*) COUNT="${arg#--count=}" ;;
        [0-9]*) COUNT="$arg" ;;
        *)
            echo "Unknown option: $arg" >&2
            echo >&2
            print_help >&2
            exit 1
            ;;
    esac
done

printf -v RESET  '\033[0m'
printf -v BOLD   '\033[1m'
printf -v GREEN  '\033[0;32m'
printf -v RED    '\033[0;31m'
printf -v YELLOW '\033[0;33m'

if [[ -z "$COUNT" ]]; then
    read -rp "Number of rotations to run [default 10]: " COUNT
    COUNT="${COUNT:-10}"
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
    printf "%s[X] Invalid count: '%s' (must be a positive integer)%s\n" "$RED" "$COUNT" "$RESET"
    exit 1
fi

if [[ ! -x "$STATUS_SCRIPT" ]]; then
    printf "%s[X] Status script not found or not executable: %s%s\n" "$RED" "$STATUS_SCRIPT" "$RESET"
    exit 1
fi

wait_for_healthy() {
    local waited=0
    while (( waited < HEALTH_TIMEOUT )); do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
        if [[ "$status" == "healthy" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    return 1
}

echo "${BOLD}Mullvad exit-server discovery -- ${COUNT} rotations${RESET}"
echo "Status script: $STATUS_SCRIPT"
echo "DB file:       $DB_FILE"
echo

for ((i = 1; i <= COUNT; i++)); do
    printf "[%d/%d] rotating... " "$i" "$COUNT"
    "$STATUS_SCRIPT" --rotate >/dev/null 2>&1

    if wait_for_healthy; then
        printf "healthy. checking... "
        "$STATUS_SCRIPT" --once >/dev/null 2>&1

        LAST_LINE=$(tail -1 "$DB_FILE" 2>/dev/null)
        if [[ -n "$LAST_LINE" ]]; then
            IFS='|' read -r ts server ip city country status <<< "$LAST_LINE"
            printf "%slogged: %s (%s, %s)%s\n" "$GREEN" "$server" "$city" "$country" "$RESET"
        else
            printf "%schecked, but nothing logged (no hostname in response)%s\n" "$YELLOW" "$RESET"
        fi
    else
        printf "%stimed out waiting for healthy -- skipping this rotation%s\n" "$RED" "$RESET"
    fi
done

echo
echo "${BOLD}Discovery complete. Distinct servers found so far:${RESET}"
if [[ -f "$DB_FILE" ]]; then
    cut -d'|' -f2 "$DB_FILE" | sort -u | while read -r s; do
        echo "  - $s"
    done
else
    echo "  (no history file yet)"
fi
