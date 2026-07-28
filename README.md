# aTrust Surge Bridge

Run the HITSZ Sangfor aTrust client inside a small Colima VM while keeping
Surge Enhanced Mode as the only host-level tunnel owner.

The bridge exposes loopback-only SOCKS, HTTP, VNC, and noVNC endpoints. Surge
uses a native fallback group that prefers campus `DIRECT` access and uses the
container SOCKS proxy only when direct access to JW is unavailable.

## What it solves

Native aTrust and Surge Enhanced Mode can both claim `198.18.0.0/16`-style
FakeIP routes. Running both tunnels on macOS may disconnect normal Internet
traffic. This project keeps aTrust's tunnel, FakeDNS mapping, browser callback,
and device state inside an isolated Linux VM.

```text
Browser / SSH
      │
      ▼
Surge Enhanced Mode
      │
      ├── campus: DIRECT
      │
      └── outside: 127.0.0.1:1080 ── Colima ── aTrust ── HITSZ intranet
```

## Requirements

- Apple Silicon Mac
- Surge Mac with Enhanced Mode
- Homebrew
- HITSZ aTrust account and access to `https://trust.hitsz.edu.cn`

Install the command-line dependencies:

```bash
brew install colima docker docker-compose docker-buildx gum
```

`gum` is optional. Without it, `hitsz` automatically uses plain text.

## Install

```bash
git clone https://github.com/hhh2210/atrust-surge-bridge.git
cd atrust-surge-bridge
mkdir -p ~/.local/bin
ln -sfn "$PWD/bin/hitsz" ~/.local/bin/hitsz
```

The default Surge source profile is:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/surge/Ash_origin.conf
```

Override it when needed:

```bash
export SURGE_SOURCE="$HOME/path/to/your/profile.conf"
```

Generate and validate a staging copy:

```bash
./bin/render-surge-preview
```

Review the diff, place `HITSZ-aTrust.dconf` beside the real Surge profile,
apply the proposed include/group/rule changes, and reload Surge manually. The
script never edits or reloads the live profile.

Important: if `[Proxy]` is assembled with `#!include`, keep the local proxy in
the detached `HITSZ-aTrust.dconf`. Do not insert an inline proxy beside the
include directive.

## Daily use

```bash
# Interactive menu
hitsz

# Outside campus: start and verify isolated aTrust
hitsz up

# On campus or when unused: stop Docker and Colima
hitsz down

# Show routing, JW health, VM, VPN, and SOCKS state
hitsz status
```

The TUI uses a compact color card in an interactive terminal. Set
`NO_COLOR=1` or `HITSZ_PLAIN=1` for stable plain-text output.

```text
╭───────────────────────────────────────╮
│  HITSZ ACCESS                         │
│  ● Campus Direct                      │
│                                       │
│    JW        HTTP 200 · DIRECT        │
│    Docker    OFF                      │
│    VPN       DISCONNECTED             │
│    SOCKS     127.0.0.1:1080 · CLOSED  │
╰───────────────────────────────────────╯
```

`hitsz up` starts a native-arm64 Colima VM limited to 1 CPU, 1 GiB RAM, and an
8 GiB sparse disk. It waits for the aTrust route, opens loopback-only noVNC if
interactive login is required, repairs the known Dante/FakeDNS cache mismatch,
and retests the Surge group. `hitsz down` removes the container and stops the
VM while preserving the named login volumes.

## Surge policy

The detached proxy is:

```ini
[Proxy]
HITSZ-aTrust = socks5, 127.0.0.1, 1080
```

The routing group performs a service-level health check and prefers direct
access:

```ini
[Proxy Group]
HITSZ = fallback, DIRECT, HITSZ-aTrust, url=https://jw.hitsz.edu.cn/, interval=60, timeout=3, evaluate-before-use=true
```

The confirmed rules are:

```ini
DOMAIN,jw.hitsz.edu.cn,HITSZ
IP-CIDR,10.248.16.0/20,HITSZ,no-resolve
```

These HITSZ-specific addresses were verified in July 2026. Reconfirm them
before adapting the project to another institution or VPN deployment.

## Adaptive SSH

`bin/ssh-connect` is an optional `ProxyCommand`. It requires a real direct SSH
host-key reply rather than trusting a TCP handshake; if the direct SSH path is
not usable, it falls back to the aTrust SOCKS endpoint.

```sshconfig
Match final host 10.249.*
    ProxyCommand /absolute/path/to/atrust-surge-bridge/bin/ssh-connect %h %p
```

Set `HITSZ_SSH_DEBUG=1` to print the selected path. The default direct probe
timeout is two seconds and can be changed with `HITSZ_DIRECT_PROBE_TIMEOUT`.

## Login and persistence

The login UI is available only on loopback:

```text
http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale
```

The named volumes preserve container-local aTrust databases, device identity,
and login state. Runtime sockets and lock files are removed at start. The
launcher never stores or types school credentials. Close the in-container
Chromium after login with:

```bash
./bin/trim-browser
```

## Security boundaries

- All published ports bind to `127.0.0.1`.
- `.env`, Docker credentials, buildx state, and login volumes are excluded from
  Git.
- Do not copy native macOS aTrust state into the container.
- Do not publish real credentials, cookies, session tickets, or device IDs.
- This repository does not redistribute Sangfor/aTrust binaries; the Dockerfile
  derives from the pinned upstream container image at build time.

See [SECURITY.md](SECURITY.md) before reporting a security issue.

## Acknowledgements

- [Hagb/docker-atrust](https://github.com/Hagb/docker-atrust)
- [Colima](https://github.com/abiosoft/colima)
- [Surge](https://nssurge.com/)
- [Charmbracelet Gum](https://github.com/charmbracelet/gum)

## License

MIT. The license covers this repository's original scripts and documentation,
not Sangfor/aTrust, Surge, or third-party container contents.
