#!/usr/bin/env bash
set -uo pipefail

PREFIX="/usr/local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf -v RESET  '\033[0m'
printf -v BOLD   '\033[1m'
printf -v GREEN  '\033[0;32m'
printf -v RED    '\033[0;31m'

print_help() {
    cat <<HELP
install.sh - install mullvad-status and mullvad-discovery

USAGE:
    ./install.sh [OPTIONS]

Copies mullvad-status.sh and mullvad-discovery.sh from this directory
into PREFIX, dropping the .sh extension and marking them executable.
Uses sudo for the copy/chmod steps, since PREFIX is typically owned by
root.

OPTIONS:
    --prefix=DIR    Install into DIR instead of $PREFIX.
    -h, --help      Show this help and exit.

EXAMPLES:
    ./install.sh
    ./install.sh --prefix=\$HOME/.local/bin
HELP
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) print_help; exit 0 ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        *)
            echo "Unknown option: $arg" >&2
            echo >&2
            print_help >&2
            exit 1
            ;;
    esac
done

SCRIPTS=("mullvad-status" "mullvad-discovery")

for name in "${SCRIPTS[@]}"; do
    src="$SCRIPT_DIR/$name.sh"
    if [[ ! -f "$src" ]]; then
        printf "%s[X] Not found: %s%s\n" "$RED" "$src" "$RESET"
        exit 1
    fi
done

mkdir -p "$PREFIX" 2>/dev/null || sudo mkdir -p "$PREFIX"

for name in "${SCRIPTS[@]}"; do
    src="$SCRIPT_DIR/$name.sh"
    dest="$PREFIX/$name"

    if [[ -w "$PREFIX" ]]; then
        cp "$src" "$dest"
        chmod +x "$dest"
    else
        sudo cp "$src" "$dest"
        sudo chmod +x "$dest"
    fi

    printf "%s[OK] Installed %s -> %s%s\n" "$GREEN" "$name.sh" "$dest" "$RESET"
done

echo
echo "${BOLD}Done.${RESET} Run 'mullvad-status --help' to get started."
echo "Settings are auto-created on first run at:"
echo "    \${MULLVAD_DATA_DIR:-\$HOME/.local/share/mullvad-status}/mullvad.conf"
echo "Edit that file to match your own gluetun setup before using --rotate or --heal."
