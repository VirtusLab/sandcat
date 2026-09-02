# Self-hosted NetBird management server

Sandcat does not create or start a NetBird management server. Run this
compose stack yourself (or use NetBird's official installer), then point
sandcat at the URL.

This layout matches NetBird's
[getting-started.sh](https://docs.netbird.io/selfhosted/selfhosted-quickstart#installation-script)
exposed-ports mode, tuned for localhost.

For a VM with a public domain, prefer the official installer instead of this
compose file:

```bash
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash
```

Docs: https://docs.netbird.io/selfhosted/selfhosted-quickstart#installation-script

## 1. Start the stack

You cannot omit `server.authSecret`: combined 0.72 fails with
`authSecret is required when running local relay`. `store.encryptionKey` is
not a “off” switch either — leave it empty and recreates can mint a new key
and make existing setup keys / PATs unreadable. Generate both on the fly and
keep them:

```bash
cd docs/examples/netbird-server
chmod +x start.sh
./start.sh --secrets-from "$HOME/.config/sandcat/netbird-server/config.yaml"
```

That copies `authSecret` and `encryptionKey` into gitignored `config.local.yaml` at
start time and does **not** write them to `netbird-server.env`. Recreate:

```bash
./start.sh --secrets-from "$HOME/.config/sandcat/netbird-server/config.yaml" \
  --force-recreate netbird-server
```

Or `NETBIRD_SECRETS_CONFIG=/path/to/config.yaml ./start.sh`.

Without `--secrets-from`, `start.sh` still generates empty keys into
`netbird-server.env` (needed if you have no existing config). `--prepare-only`
stops after writing `config.local.yaml` (no Docker).

Edit `exposedAddress` in tracked `config.yaml`; `start.sh` copies it into
`config.local.yaml` on each run. Combined `netbird-server` advertises that
host for management and signal (TCP). `localhost` is fine for host tools
and the dashboard; mitmproxy inside Docker cannot use it.

Do **not** put sandcat or proxy-peer on the netbird-server compose network.

On Colima, `host-gateway` / `192.168.5.2` work for TCP but UDP 3478 hairpins.
Keep embedded STUN (`stunPorts` only — do **not** set `server.stuns`, that
stops the listener). Map the advertised name to docker0 in peer compose:

```yaml
# config.yaml — embedded STUN stays on
server:
  exposedAddress: "http://host.docker.internal:33073"
  stunPorts: [3478]

# mitmproxy / proxy-peer
extra_hosts:
  - "host.docker.internal:172.17.0.1"
```

`netbird_enrollment_management_url` may stay on the LAN IP (TCP still works).
`exposedAddress` is what peers use for STUN; it does not have to match the
enrollment URL, but it must not be `localhost`.

## 2. Verify the API

```bash
curl -s http://localhost:33073/api/instance
```

Expect `"setup_required": true` before bootstrap. Use **http** (not https) and
the **/api/** prefix.

## 3. Bootstrap the first admin

```bash
curl -fsS -X POST "http://localhost:33073/api/setup" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "admin@example.com",
    "name": "Admin",
    "password": "choose-a-long-random-password",
    "create_pat": true,
    "pat_expire_in": 7
  }'
```

Save the returned `personal_access_token` for `netbird_api_token` in
`~/.config/sandcat/settings.json`. See
[NetBird automated setup](https://docs.netbird.io/selfhosted/automated-setup).

## 4. Open the dashboard

```text
http://localhost:8080
```

Or the setup wizard: `http://localhost:8080/setup` (before step 4). Create a
**Setup Key** for peer enrollment.

## 5. Point sandcat at the server

```bash
sandcat init --agent cursor --ide vscode --netbird \
  --netbird-management-url http://localhost:33073 --name myproject
```

Host tools and the browser use `localhost`. mitmproxy needs the Docker host IP
in `netbird_enrollment_management_url`:

```json
"netbird_management_url": "http://localhost:33073",
"netbird_enrollment_management_url": "http://192.168.5.2:33073",
"netbird_enrollment_key": "<setup-key from dashboard>",
"netbird_api_token": "<pat from /api/setup or dashboard>"
```

Replace `192.168.5.2` with your Docker host IP (`colima status -j` on Colima)
for **enrollment TCP**. Set `server.exposedAddress` to
`http://host.docker.internal:33073` so STUN uses the same published ports.
If `exposedAddress` is `localhost`, peers dial `localhost` / `[::1]` inside
the container. Recreate the server after changing it:

```bash
cd docs/examples/netbird-server
./start.sh --secrets-from "$HOME/.config/sandcat/netbird-server/config.yaml" \
  --force-recreate netbird-server
```

Then recreate mitmproxy (`sandcat run --force-recreate mitmproxy`).

## Troubleshooting

### Peers dial `[::1]:33073` after enrollment

The management server is still advertising `http://localhost:33073` in
`config.yaml` `server.exposedAddress`. Set it to
`http://host.docker.internal:33073`, recreate netbird-server, then recreate
mitmproxy (needs `extra_hosts: ["host.docker.internal:172.17.0.1"]`).

### STUN `context deadline exceeded` / peers stuck `Connecting`

`server.stuns` in config.yaml **disables** the embedded UDP 3478 listener —
every STUN probe then times out, including `172.17.0.1`. Leave `stunPorts`
only. On Colima, `host.docker.internal` via `host-gateway` is `192.168.5.2`
(TCP ok, UDP hairpin). Set peer `extra_hosts` to
`host.docker.internal:172.17.0.1`, recreate server **without** `stuns:`, then
recreate mitmproxy and proxy-peer. Probe from mitmproxy: resolve
`host.docker.internal` to `172.17.0.1` and STUN that IP.

### Port clash

Default ports **8080** (dashboard) and **33073** (management API) may already
be in use. Change `NETBIRD_DASHBOARD_HTTP_PORT` and `NETBIRD_MGMT_API_PORT` in
`netbird-server.env`, then update `config.yaml` and `dashboard.env` URLs to
match.

### `curl: (52) Empty reply` or SSL errors on port 33073

- Use **`http://localhost:33073/api/...`** — not `https://` and not `/setup`
  (dashboard route; API is `/api/setup`).
- Ensure compose maps **`33073:80`** to `netbird-server`, not `33073:443`.
- Recreate after config changes: `./start.sh --force-recreate netbird-server`

### `/api/setup` returns "not authenticated"

Embedded IdP must be enabled in `config.yaml` (`server.auth.issuer`). If
needed, reset data:

```bash
docker compose --env-file netbird-server.env down -v
./start.sh
```
