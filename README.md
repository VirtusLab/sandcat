# Sandcat

Sandcat routes all dev container traffic through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard. It captures HTTP/S,
DNS, and all other TCP/UDP traffic without per-tool proxy configuration.
A network policy engine controls which requests are allowed, and a secret
substitution system ensures dev containers never see real credentials.

## Quick start

Add sandcat as a git submodule:

```sh
git submodule add <url> .devcontainer/sandcat
```

Create your settings file:

```sh
mkdir -p ~/.config/sandcat
cp .devcontainer/sandcat/settings.example.json ~/.config/sandcat/settings.json
# Edit with your real values
```

## Compose integration

In your `.devcontainer/compose.yml`, include sandcat's compose file and
add your app service:

```yaml
include:
  - path: sandcat/compose.yml

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    network_mode: "service:wg-client"
    volumes:
      - ..:/workspaces/project:cached
      - mitmproxy-config:/mitmproxy-config:ro
    command: sleep infinity
    depends_on:
      wg-client:
        condition: service_healthy
```

In your `.devcontainer/Dockerfile`, copy and use `sandcat-init.sh` as
the entrypoint:

```dockerfile
FROM mcr.microsoft.com/devcontainers/javascript-node:22
COPY sandcat/scripts/sandcat-init.sh /usr/local/bin/sandcat-init.sh
RUN chmod +x /usr/local/bin/sandcat-init.sh
ENTRYPOINT ["sandcat-init.sh"]
```

The entrypoint installs the mitmproxy CA certificate into the system
trust store and loads placeholder environment variables for secret
substitution before handing off to the container's main command.

## Settings format

`~/.config/sandcat/settings.json`:

```json
{
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "value": "sk-ant-real-key-here",
      "hosts": ["api.anthropic.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*", "method": "GET"},
    {"action": "allow", "host": "*.github.com", "method": "POST"},
    {"action": "allow", "host": "*.anthropic.com"},
    {"action": "allow", "host": "*.claude.com"}
  ]
}
```

Warning: allowing all GET-traffic, all traffic from GitHub or in fact any not-fully-trusted/controlled site,
leaves the possibility of a prompt injection attack. Blocking `POST`-traffic might prevent code from being
exfiltrated, but malicious code might still be generated as part of the project.

## Network access rules

The `network` array defines ordered access rules evaluated top-to-bottom.
First matching rule wins (like iptables). If no rule matches, the request
is **denied**.

Each rule has:
- `action` — `"allow"` or `"deny"` (required)
- `host` — glob pattern via fnmatch (required)
- `method` — HTTP method to match; omit to match any method (optional)

### Examples

With the rules above:
- `GET` to any host → **allowed** (rule 1)
- `POST` to `api.github.com` → **allowed** (rule 2)
- `POST` to `api.anthropic.com` → **allowed** (rule 3)
- `POST` to `example.com` → **denied**
- `PUT` to `example.com` → **denied**
- Empty network list → all requests **denied** (default deny)

## Secret substitution

Dev containers never see real secret values. Instead, environment
variables contain deterministic placeholders
(`SANDCAT_PLACEHOLDER_<NAME>`), and the mitmproxy addon replaces them
with real values when requests pass through the proxy.

Inside the container, `echo $ANTHROPIC_API_KEY` prints
`SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`. When a request containing that
placeholder reaches mitmproxy, it's replaced with the real key — but only
if the destination host matches the `hosts` allowlist.

### Host patterns

The `hosts` field accepts glob patterns via `fnmatch`:

- `"api.anthropic.com"` — exact match
- `"*.anthropic.com"` — any subdomain
- `"*"` — allow all hosts (use with caution)

### Leak detection

If a placeholder appears in a request to a host **not** in the allowlist,
mitmproxy blocks the request with HTTP 403 and logs a warning. This
prevents accidental secret leakage to unintended services.

### How it works internally

1. The mitmproxy container mounts `~/.config/sandcat/settings.json`
   (read-only) and the `sandcat_addon.py` addon script.
2. On startup, the addon reads `settings.json` and writes
   `placeholders.env` to the `mitmproxy-config` shared volume
   (`/home/mitmproxy/.mitmproxy/placeholders.env`). This file contains
   lines like `export ANTHROPIC_API_KEY="SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY"`.
3. App containers mount `mitmproxy-config` read-only at
   `/mitmproxy-config/`. The shared entrypoint (`sandcat-init.sh`)
   sources `placeholders.env` after installing the CA cert, so every
   process gets the placeholder values as env vars.
4. On each request, the addon first checks network access rules. If
   denied, the request is blocked with 403.
5. If allowed, the addon checks for secret placeholders in the request,
   verifies the destination host against the secret's allowlist, and
   either substitutes the real value or blocks the request with 403
   (leak detection).

Real secrets never leave the mitmproxy container.

### Disabling

Delete or rename `~/.config/sandcat/settings.json`. If the file is
absent, the addon disables itself — no network rules are enforced and no
placeholder env vars are set.

### Claude Code

Claude Code ignores `ANTHROPIC_API_KEY` until onboarding is complete.
Without `{"hasCompletedOnboarding": true}` in `~/.claude.json`, it
prompts for browser-based login instead of using the key. The dev
container automatically sets this on startup (via
`scripts/post-create.sh`) if not already present, so Claude Code picks
up the API key from secret substitution without manual setup.

## Architecture

```
                network_mode
┌──────────────┐  shares net  ┌──────────────┐  WG tunnel  ┌──────────────┐
│   app        │ ──────────── │  wg-client   │ ─────────── │  mitmproxy   │ ── internet
│ (no NET_ADMIN)              │  (NET_ADMIN) │             │  (mitmweb)   │
└──────────────┘              └──────────────┘             └──────────────┘
                                                             localhost:8081
                                                             pw: mitmproxy
```

- **mitmproxy** runs `mitmweb --mode wireguard`, creating a WireGuard
  server and storing key pairs in `wireguard.conf`.
- **wg-client** is a dedicated networking container that derives a
  WireGuard client config from those keys, sets up the tunnel with `wg`
  and `ip` commands, and adds iptables kill-switch rules. Only this
  container has `NET_ADMIN`. No user code runs here.
- **App containers** share `wg-client`'s network namespace via
  `network_mode`. They inherit the tunnel and firewall rules but cannot
  modify them (no `NET_ADMIN`). They install the mitmproxy CA cert into
  the system trust store at startup so TLS interception works.
- The mitmproxy web UI on port 8081 shows all intercepted traffic
  (password: `mitmproxy`).

## Testing the proxy

A lightweight `test` container is included in sandcat's own dev container
for verifying the proxy works. Start it (from the `.devcontainer/`
directory):

```sh
docker compose --profile test run --rm test bash
```

Inside the container, verify HTTPS works through the tunnel:

```sh
# Should return 200 (mitmproxy CA is trusted)
curl -s -o /dev/null -w '%{http_code}\n' https://example.com

# Traffic should appear in the mitmproxy web UI
curl https://httpbin.org/get
```

Then open http://localhost:8081 and log in with password `mitmproxy` to
confirm the requests show up in the web UI.

To verify the kill switch blocks direct traffic:

```sh
# Should fail — iptables blocks direct eth0 access
curl --max-time 3 --interface eth0 http://1.1.1.1

# Should fail — no NET_ADMIN to modify firewall
iptables -F OUTPUT
```

To verify secret substitution for the github token:

```sh
gh auth status
```

## Unit tests

```sh
cd scripts && pytest test_sandcat_addon.py -v
```

## Notes

### Why not wg-quick?

`wg-quick` calls `sysctl -w net.ipv4.conf.all.src_valid_mark=1`, which
fails in Docker because `/proc/sys` is read-only. The equivalent sysctl
is set via the `sysctls` option in `compose.yml`, and the entrypoint
script handles interface, routing, and firewall setup manually.

### Rust TLS

Rust programs using `rustls` with the `webpki-roots` crate bundle CA
certificates at compile time and will not trust the mitmproxy CA. Use
`rustls-tls-native-roots` in reqwest so it reads the system CA store at
runtime instead.
