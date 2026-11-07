# aTrust Surge Bridge

Run the HITSZ Sangfor aTrust client inside a small Colima VM while keeping
Surge Enhanced Mode as the only host-level tunnel owner.

The bridge exposes loopback-only SOCKS, HTTP, VNC, and noVNC endpoints. Surge
uses a persistent Surge selection that `hitsz up` switches to the container
SOCKS proxy and `hitsz down` switches back to campus `DIRECT`.

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
brew install colima docker docker-compose docker-buildx jq gum
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

## Site and backend boundary

`sites/hitsz.sh` defines the Surge policies, health target, and loopback SOCKS
endpoint. `ATRUST_SITE` selects a bundled profile (default: `hitsz`) and fails
closed for unknown or incomplete profiles. `lib/surge_lifecycle.sh` owns the
backend-neutral selection, live verification, probes, and rollback; the current
`lib/surge_mode.sh` adapter supplies real-aTrust/Colima callbacks. Another
backend can reuse that lifecycle, but still needs an explicit adapter and a
tested staged Surge-profile renderer.

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

# Reopen noVNC with its loopback-only VNC credential filled automatically
hitsz login

# On campus or when unused: stop Docker and Colima
hitsz down

# Show routing, JW health, VM, VPN, and SOCKS state (read-only)
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
8 GiB sparse disk. If interactive login is required, the spinner stops first,
shows a fallback credential card, and opens noVNC with the local VNC credential
already filled. The secret travels only in a URL fragment (which browsers do
not send to the HTTP server). A cache-resistant entry page removes it before
loading noVNC and receives a non-secret nonce on every open, so an older cached
noVNC module cannot leave the password in the address bar. After login, the
command repairs the known Dante/FakeDNS cache mismatch, activates the Surge
route, verifies a real JW request, and stops the login-only Chromium process to
release VM memory. `hitsz down` removes the container and stops the VM while
preserving all three login-state volumes.

`hitsz up` restores the isolated tunnel, activates the Surge route, and passes
the first JW request in the foreground; a green `网络已可用` milestone appears
as soon as that request succeeds and the command returns. The 30-second health
window and Chromium cleanup then continue in the background
(`~/.local/state/atrust-surge-bridge/hitsz/settle.log`, override with `BRIDGE_STATE_DIR` or `HITSZ_STATE_DIR`): a route
regression still rolls Surge back to a verified `DIRECT`, and `hitsz status`
shows `Settle` while the check runs, after it failed, or when it was
interrupted before recording a result (for example by a restart). Each
background check carries a generation token, and any later activation or
`hitsz down` cancels it first, so a stale check can never revert a newer
connection. Route changes are serialized by a kernel `flock` on
`settle.lock` (taken through the system `perl`, since macOS has no `flock(1)`),
so a crashed command never leaves a stale lock behind. `hitsz down` refuses to
stop the bridge while another `hitsz` command still holds the route, keeps it
until the VM has stopped, and an `up` whose connection setup fails returns
a `HITSZ-aTrust` selection to `DIRECT` instead of leaving it unchecked. Set
`HITSZ_SETTLE_FOREGROUND=1` to keep the old blocking behaviour.
If the bridge container is already running, `hitsz up` reuses it instead of
rebuilding the image or recreating the container. On a cold start the image is
rebuilt only when a SHA-256 of the build context (Dockerfile, `container/`,
`patches/`, and the pinned base digest) differs from the label on the local
image; a cached buildx run would otherwise still spend about three seconds
resolving the base image against the registry. `HITSZ_FORCE_BUILD=1` forces
a rebuild. This keeps a healthy aTrust
session stable when the command is repeated. Route activation allows up to 30
seconds for the real JW SOCKS path to become usable; on failure it requests
`DIRECT`, verifies the live Surge selection, and reports an error if that
rollback cannot be confirmed. It points the operator to `hitsz login` when
fresh authentication is required. After pulling a revision that changes the
Docker image or container scripts, run `hitsz down` once before the next
`hitsz up` so the new image is built and deployed.

On startup, `hitsz up` first gives the trusted-terminal flow up to 30 seconds
to renew silently. A valid CAS SSO session passes the CAS login page within the
same second, so when the in-container Chromium window still shows the CAS login
form on two consecutive readiness checks (about 2–4 seconds), `hitsz up` opens
noVNC immediately instead of waiting out the full grace period
(`HITSZ_CAS_FORM_REVEAL_CHECKS`, `ATRUST_CAS_LOGIN_TITLE_RE`). For the pinned aTrust 2.5.16.20 client, it uses a fail-closed
GUI guard: the client window must be uniquely visible, owned by the expected
`aTrustTray` process, match the expected geometry, and show `Log In` in an OCR
crop before one coordinate click is sent. The click only launches the isolated
browser; no credential is passed to it. A 30-second cooldown and a shared
browser lock make concurrent host/keeper triggers idempotent. If the guard or
renewal fails, `hitsz up` opens noVNC instead. The default geometry can be
adapted with the `ATRUST_LOGIN_*` variables in `compose.yaml` when a client
version or display scale changes. Failed OCR/window verification is sampled at
most three times and backs off for five minutes instead of polling continuously.

While the container remains running, a tiny in-container keeper repeats that
guarded trigger after a session timeout. After the restored route stays healthy
for 30 seconds, it asks only the profile-scoped Chromium root process to
terminate, waits for every profile-identifiable Chromium/crashpad process to
exit, and then removes unowned stale singleton files. A timeout is reported as
a warning instead of a clean stop.
If a manual/CAS login remains offline for 10 minutes, the keeper cleanly closes
Chromium and latches automatic retries off. This prevents both an unattended
browser from exhausting the 1 GiB VM and a stale saved password from being
resubmitted until account lockout. `hitsz login` or a new `hitsz up` grants one
fresh 60-second, one-shot browser-open permit while automatic retries remain
latched; the latch is cleared only after tunnel health returns. Override the
10-minute offline-browser timeout with `ATRUST_BROWSER_OFFLINE_TTL_SECONDS`;
failed OCR triggers separately back off for five minutes.
If the trusted-device grant itself expires, the browser remains open for manual
SSO; once automatic retries are latched, `hitsz status` reports `需手动登录`.
On the exact HITSZ CAS login origin,
a bundled extension first verifies that the CAS `service` target is the HITSZ
aTrust callback and pre-selects the form's seven-day `rememberMe` session once,
so a manual noVNC login also lets the next relaunch within seven days pass CAS
SSO without a form. It then waits for Chromium's native password autofill and
clicks the exact scoped submit control once. The extension never reads field values and has no network
permissions. Project code never receives or writes the school password, but if
you enable Chromium's password manager, its saved-password database is part of
the persistent `atrust-surge-data` browser profile. Treat that volume as
sensitive login state. After a successful CAS return, the launcher requires 30
continuous seconds of healthy tunnel routing, verifies JW again, requests the
clean browser shutdown described above, and performs one final JW request
before reporting success.

After the isolated tunnel passes a real JW request, `hitsz up` persists the
`HITSZ` selection as `HITSZ-aTrust`. This avoids false-positive `DIRECT` latency
tests outside campus and survives a Surge reload. `hitsz down` selects and
verifies `DIRECT` before stopping Docker; if the live selection cannot be
verified, it leaves the bridge running and exits with an error. Neither command
edits or reloads the Surge profile.

`hitsz status` reads that live selection directly from Surge. When aTrust is
selected but its tunnel is disconnected, status skips the JW request and shows
`登录恢复中` while the isolated browser is active, `待自动恢复` while the
keeper may still renew the trusted session, or `需手动登录` only when its retry
latch is set and no login browser remains. It never sends the status probe into
an unavailable SOCKS path. The
container also rejects the verified HITSZ private range `10.248.0.0/15` unless
Linux routes it through `utun7`; this prevents a disconnected tunnel from
feeding the same request back into Surge Enhanced Mode without blocking
aTrust's pre-tunnel FakeIP login flow.

## Surge policy

The detached proxy is:

```ini
[Proxy]
HITSZ-aTrust = socks5, 127.0.0.1, 1080
```

The routing group is selected explicitly by the lifecycle command:

```ini
[Proxy Group]
HITSZ = select, DIRECT, HITSZ-aTrust
```

The confirmed rules are:

```ini
DOMAIN,jw.hitsz.edu.cn,HITSZ
IP-CIDR,10.248.16.0/20,HITSZ,no-resolve
```

These HITSZ-specific addresses were verified in July 2026. Reconfirm them
before adapting the project to another institution or VPN deployment.

The container also pins the verified aTrust control endpoint
`trust.hitsz.edu.cn` to `219.223.250.11`. Without that mapping, aTrust may send
its own gateway through an unmapped `198.18/16` FakeIP after login while the
data tunnel remains deceptively usable. Override `ATRUST_GATEWAY_IP` if the
school changes the gateway address.

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
http://127.0.0.1:6080/atrust-vnc.html
```

The named volumes preserve `/root`, `/home/sangfor`, and
`/usr/share/sangfor/.aTrust`, covering Chromium/aTrust cookies, per-user aTrust
settings, device identity, and system databases. Runtime sockets and stale
singleton files are removed only when no profile-scoped browser process or
socket owner remains. The launcher itself only auto-fills the generated
loopback VNC password; browser-native autofill remains Chromium's
responsibility and may
persist a saved password under `/root` as described above. A school-side
session timeout can still require a fresh browser login even though these local
volumes remain intact. A successful `hitsz up` closes Chromium automatically;
the manual fallback is:

```bash
./bin/trim-browser
```

## Security boundaries

- All published ports bind to `127.0.0.1`.
- The verified HITSZ private range `10.248.0.0/15` fails closed unless it uses
  container interface `utun7`; aTrust FakeIP remains available for pre-tunnel
  login.
- Automatic CAS submit is restricted to the exact HITSZ CAS origin and the
  `https://trust.hitsz.edu.cn/passport/v1/auth/cas/` service target.
- The persistent volumes can contain cookies, device identity, session state,
  and Chromium-saved passwords. Protect Docker/Colima storage as credentials.
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

### HITSZ printer forward (macOS)

An existing `M280nw_aTrust` CUPS queue pointing to
`ipp://127.0.0.1:8631/ipp/print` enables the optional printer integration.
Install `socat` (with SOCKS5 support) and Python 3 before using it.
`hitsz up` registers a user LaunchAgent that forwards loopback port 8631
through the existing SOCKS endpoint to `10.249.42.42:631`. launchd keeps the
forward alive across terminal exits and restarts it after a crash. At the next
macOS login it starts again; reaching the printer still requires the HITSZ VPN.
`hitsz down` unloads the agent and removes its login registration before
stopping the VM. Neither command creates a printer queue or submits print jobs.

`hitsz status` includes the printer path's health (a response from the printer,
not just an open local port). For repairing only this path without restarting
the VPN:

```sh
hitsz printer up
hitsz printer status
hitsz printer down
```

An unmanaged listener on 8631 is reported, never killed or adopted. Logs are
under `~/Library/Logs/hitsz/printer.log`. A failed printer start warns without
interrupting VPN stability checks. `HITSZ_PRINTER_DISABLED=1` disables automatic
printer startup. The integration is skipped on other site profiles and machines
without the matching queue.
