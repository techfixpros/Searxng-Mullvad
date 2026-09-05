# Searxng-Mullvad

Small bash toolkit for monitoring, rotating, and self-healing a
[gluetun](https://github.com/qdm12/gluetun)-based Mullvad WireGuard
tunnel in Docker. Originally built for a SearXNG + gluetun setup, but
generic underneath -- it works with any container (or pair of
containers) sharing gluetun's network via
`network_mode: "service:gluetun"`, not just SearXNG.

- **`mullvad-status`** -- live dashboard / one-shot status check,
  exit-server history log, country rotation, self-healing restart, and
  systemd scheduling, all in one script.
- **`mullvad-discovery`** -- rapidly cycles through your configured
  countries to populate the exit-server history in one run.

## Requirements

- A gluetun container already running Mullvad WireGuard, **with a
  working Docker `HEALTHCHECK`** defined in its compose service (both
  `--heal` and `mullvad-discovery` rely on `docker inspect`'s health
  status).
- Docker Compose v2 (the `docker compose` plugin syntax -- not the
  standalone `docker-compose` v1 binary).
- Bash, `awk`, `sed`, `grep`, GNU `date` (used for `date -d` and
  `date -Iseconds`; other `date` implementations, e.g. macOS/BSD, are
  not currently supported).
- `sudo` and `systemctl`, only if you use `--service` to install the
  scheduled timers.

This was built and tested on Ubuntu Server; it should work on any
systemd-based Linux distro with a reasonably current bash and
coreutils.

## Install

```bash
git clone https://github.com/techfixpros/Searxng-Mullvad.git
cd Searxng-Mullvad
./install.sh
```

This copies `mullvad-status.sh` and `mullvad-discovery.sh` into
`/usr/local/bin` as `mullvad-status` and `mullvad-discovery` (extension
dropped, executable). Use `sudo` automatically if `/usr/local/bin`
isn't writable by your user.

To install somewhere else instead:

```bash
./install.sh --prefix=$HOME/.local/bin
```

## Shell completion (zsh)

Tab completion for both commands is included as two Oh My Zsh plugins
(one per command -- Oh My Zsh recognizes a plugin folder automatically
when it contains a completion file whose name matches the folder,
e.g. `mullvad-status/_mullvad-status`, no extra plugin file needed):

```bash
mkdir -p ~/.oh-my-zsh/custom/plugins/mullvad-status
mkdir -p ~/.oh-my-zsh/custom/plugins/mullvad-discovery
cp zsh/_mullvad-status ~/.oh-my-zsh/custom/plugins/mullvad-status/
cp zsh/_mullvad-discovery ~/.oh-my-zsh/custom/plugins/mullvad-discovery/
```

Then append both to the existing `plugins=(...)` line in `~/.zshrc`
(don't replace whatever's already there -- just add these two to the
list). For example, if your line currently reads:

```zsh
plugins=(git docker)
```

change it to:

```zsh
plugins=(git docker mullvad-status mullvad-discovery)
```

Restart your shell (or `exec zsh`) to pick them up. If completions
don't show up right away:

```bash
rm -f ~/.zcompdump*
compinit
```

**Without Oh My Zsh**, add the `zsh/` directory to your own
`fpath` before `compinit` runs in `.zshrc`:

```zsh
fpath=(/path/to/Searxng-Mullvad/zsh $fpath)
autoload -Uz compinit && compinit
```

## Example stack

If you don't already have a gluetun + Mullvad stack running, this repo
includes a working example to start from:
[`docker-compose.yml.example`](./docker-compose.yml.example) and
[`active-mullvad.env.example`](./active-mullvad.env.example).

```bash
cp docker-compose.yml.example docker-compose.yml
cp active-mullvad.env.example active-mullvad.env
```

Edit `active-mullvad.env` with your own Mullvad WireGuard credentials:

1. Mullvad account page -> **WireGuard configuration** -> Generate key
2. Copy `PrivateKey` into `WIREGUARD_PRIVATE_KEY`
3. Copy `Address` into `WIREGUARD_ADDRESSES` (keep the `/32`)
4. Set `SERVER_COUNTRIES` to any country Mullvad has servers in

Both files are gitignored once copied, so your real key never
accidentally gets committed.

Also worth a look before bringing it up: `docker-compose.yml`'s
`FIREWALL_OUTBOUND_SUBNETS` and `SEARXNG_BASE_URL` both have
`CHANGE ME` comments next to placeholder values -- adjust those to
match your own Docker network and (if you have one) public domain.

Then bring it up:

```bash
docker compose up -d
```

This is a three-container stack -- `gluetun` (the Mullvad tunnel),
`searxng` (sharing gluetun's network), and `valkey` (SearXNG's cache)
-- but the toolkit itself only cares about the `gluetun` container and,
optionally, one paired app container. Swap `searxng`/`valkey` for
whatever you're actually running behind gluetun if it's not SearXNG.

## Configure

Run `mullvad-status` once with no arguments. It auto-creates a config
file at:

```
~/.local/share/mullvad-status/mullvad.conf
```

Open it and edit every value to match your own setup -- an example is
included in this repo at [`mullvad.conf.example`](./mullvad.conf.example)
if you want to look before running anything. If you used the example
stack above as-is, the defaults in `mullvad.conf` already match it
except for `COMPOSE_DIR`, which you'll need to point at wherever you
put `docker-compose.yml`.

At minimum you'll need to set:

| Setting | What it is |
|---|---|
| `CONTAINER` | The actual container name of your gluetun service (from `docker ps`, not the compose service name) |
| `APP_CONTAINER` | Optional: a second container sharing gluetun's network that should restart alongside it in `--heal`. Leave blank if you don't have one. |
| `COMPOSE_DIR` | Directory containing your `docker-compose.yml` and env file |
| `ENV_FILE_NAME` | The env file (inside `COMPOSE_DIR`) whose `SERVER_COUNTRIES` line gets updated on rotation |
| `ROTATE_SERVICES` | Space-separated compose **service** names to recreate on rotation (these can differ from container names) |
| `COUNTRIES` | The countries to round-robin through -- must match what your VPN provider's gluetun integration accepts |

`mullvad-discovery` reads `CONTAINER` and `DB_FILE` from this same
file, so the two tools always agree on your setup -- there's nothing
extra to configure there.

## Usage

### Status / dashboard

```bash
mullvad-status                  # single check, print, exit
mullvad-status --monitor        # live dashboard, checks every 60s
mullvad-status --monitor --interval=30
```

The dashboard shows current connection status, public IP, location,
exit server, a real tunnel-traffic byte/packet counter (read directly
from `iptables`, independent of any external API response), and a
running table of every distinct exit server you've used, with the
current one highlighted.

### Rotation

```bash
mullvad-status --rotate
```

Advances to the next country in `COUNTRIES` (round-robin), updates
`SERVER_COUNTRIES` in your env file, and recreates the relevant compose
services.

### Self-healing

```bash
mullvad-status --heal
```

Checks `CONTAINER`'s Docker health status. If unhealthy, restarts it
(and `APP_CONTAINER`, if set, a few seconds after) and exits. Does
nothing if already healthy -- safe to run frequently on a timer.

### Scheduled rotation + healing

```bash
mullvad-status --service=install
```

Installs and enables two systemd timers:

- `mullvad-rotate.timer` -- rotates country once a day (±1h jitter)
- `mullvad-healthwatch.timer` -- checks tunnel health every minute,
  self-heals automatically if it ever goes unhealthy

```bash
mullvad-status --service=disable   # stop the timers, keep the unit files
mullvad-status --service=remove    # stop, disable, and delete everything
```

### Discovering exit servers

```bash
mullvad-discovery           # prompts for how many rotations to run
mullvad-discovery 20        # run 20 rotations back-to-back
```

For each rotation: calls `mullvad-status --rotate`, polls the
container's health status until it comes back up (rather than a fixed
sleep), then checks and logs the new exit server. Useful for quickly
building up a picture of which servers your subscription actually
gives you.

Full flag reference for either tool:

```bash
mullvad-status --help
mullvad-discovery --help
```

## History log

Exit servers are logged to a plain, pipe-delimited flat file at
`~/.local/share/mullvad-status/history.db`:

```
iso_timestamp|exit_server|ip|city|country|status
```

Only genuine server changes are logged (checking the same server
repeatedly doesn't inflate the count), so the count column reflects
distinct sessions on that server, not just how many times it happened
to be polled.

## Known limitations

- Assumes GNU coreutils (`date -d` specifically); not tested on
  macOS/BSD.
- `--heal` and `mullvad-discovery`'s health polling both depend on the
  gluetun container having a Docker `HEALTHCHECK` defined -- without
  one, `docker inspect`'s health status will just be empty and these
  features won't do anything useful.
- The `iptables`-based tunnel-traffic counter in the dashboard requires
  the container to have `NET_ADMIN` capability (typical for gluetun
  setups) and will silently show nothing if it doesn't.

## License

MIT -- see [LICENSE](./LICENSE).