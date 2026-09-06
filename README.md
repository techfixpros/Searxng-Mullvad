# Searxng-Mullvad

Bash toolkit for monitoring, rotating, and self-healing a
[gluetun](https://github.com/qdm12/gluetun)-based Mullvad WireGuard
tunnel in Docker. Works with any container (or pair of containers)
sharing gluetun's network via `network_mode: "service:gluetun"`, not
just SearXNG.

- **`mullvad-status`** -- dashboard, history log, rotation, pinning,
  self-healing, and systemd scheduling in one script.
- **`mullvad-discovery`** -- rapidly cycles through configured
  countries to populate the exit-server history.

## Requirements

- A gluetun container with a working Docker `HEALTHCHECK` defined.
- Docker Compose v2 (`docker compose`, not the old v1 binary).
- Bash, `awk`, `sed`, `grep`, GNU `date` (not tested on macOS/BSD).
- `sudo` + `systemctl`, only for `--service`/`--activate`/`--disable`.

## Install

```bash
git clone https://github.com/techfixpros/Searxng-Mullvad.git
cd Searxng-Mullvad
./install.sh                       # or: ./install.sh --prefix=$HOME/.local/bin
```

Copies both scripts into `/usr/local/bin` with the `.sh` dropped.

## Shell completion (zsh)

```bash
mkdir -p ~/.oh-my-zsh/custom/plugins/mullvad-status
mkdir -p ~/.oh-my-zsh/custom/plugins/mullvad-discovery
cp zsh/_mullvad-status ~/.oh-my-zsh/custom/plugins/mullvad-status/
cp zsh/_mullvad-discovery ~/.oh-my-zsh/custom/plugins/mullvad-discovery/
```

Add both to your existing `plugins=(...)` line in `~/.zshrc`, then
`source ~/.zshrc`. Without Oh My Zsh, add `zsh/` to your own `fpath`
before `compinit` runs.

## Example stack

No existing gluetun stack? Start from the included example:

```bash
cp docker-compose.yml.example docker-compose.yml
cp active-mullvad.env.example active-mullvad.env
```

Edit `active-mullvad.env` with your Mullvad WireGuard key/address
(account page -> WireGuard configuration -> Generate key), and check
`docker-compose.yml`'s `CHANGE ME` comments (Docker subnet, public
URL). Both files are gitignored once copied. Then `docker compose up -d`.

## Configure

Run `mullvad-status` once. It auto-creates
`~/.local/share/mullvad-status/mullvad.conf` -- edit it to match your
setup (see [`mullvad.conf.example`](./mullvad.conf.example)):

| Setting | What it is |
|---|---|
| `CONTAINER` | Actual gluetun container name (`docker ps`, not the compose service name) |
| `APP_CONTAINER` | Optional second container to restart alongside it in `--heal` |
| `COMPOSE_DIR` | Directory with your `docker-compose.yml` and env file |
| `ENV_FILE_NAME` | Env file whose `SERVER_COUNTRIES`/`SERVER_HOSTNAMES` line gets updated |
| `ROTATE_SERVICES` | Compose **service** names to recreate on rotation |
| `COUNTRIES` | Countries to round-robin through |

`mullvad-discovery` reads `CONTAINER`/`DB_FILE` from the same file.

## Usage

| Command | Does |
|---|---|
| `mullvad-status` | Single check, print, exit |
| `mullvad-status --monitor [--interval=N]` | Live dashboard, re-checks every 60s (default) |
| `mullvad-status --rotate` | Next country in `COUNTRIES`, recreates the tunnel |
| `mullvad-status --select` | Arrow-key menu: all countries, a specific country, or pin one exact exit server |
| `mullvad-status --heal` | Restart the tunnel if unhealthy (safe to run on a timer) |
| `mullvad-status --verbose` | Wide one-shot dump: every server, timer state, full config files |
| `mullvad-status --service=install\|disable\|remove` | Manage both scheduled timers together |
| `mullvad-status --activate` / `--disable` | Toggle just the rotate timer |
| `mullvad-discovery [N]` | Run N rotations back-to-back to populate history |

Full flag reference: `mullvad-status --help` / `mullvad-discovery --help`.

**Notes on `--select`:** `SERVER_COUNTRIES` and `SERVER_HOSTNAMES` are
mutually exclusive -- picking one clears the other. Afterward it checks
the rotate timer and offers the matching fix (install/enable/disable);
pinning one exit only ever offers to disable an active timer, never to
turn rotation on. If you install/enable after picking a country, it'll
also offer to scope `COUNTRIES` in `mullvad.conf` to match.

## History log

Plain pipe-delimited file at `~/.local/share/mullvad-status/history.db`:

```
iso_timestamp|exit_server|ip|city|country|status
```

Only genuine server changes are logged, so the count reflects distinct
sessions, not poll frequency. The dashboard shows the 20 most recent
(`--verbose` for the full list).

## Known limitations

- Requires GNU coreutils (`date -d`); not tested on macOS/BSD.
- `--heal` and `mullvad-discovery` need a Docker `HEALTHCHECK` on the
  container to detect health at all.
- The `iptables`-based traffic counter needs `NET_ADMIN` capability.

## License

MIT -- see [LICENSE](./LICENSE).