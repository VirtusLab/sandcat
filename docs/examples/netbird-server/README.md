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

## 1. Generate secrets

```bash
cd docs/examples/netbird-server

# Fill empty keys in netbird-server.env (keep them stable across restarts).
python3 - <<'PY'
import pathlib, re, secrets, base64
p = pathlib.Path("netbird-server.env")
text = p.read_text()
for key in ("NETBIRD_ENCRYPTION_KEY", "NETBIRD_RELAY_AUTH_SECRET"):
    value = base64.b64encode(secrets.token_bytes(32)).decode()
    text = re.sub(rf"^{key}=.*$", f"{key}={value}", text, flags=re.M)
p.write_text(text)
print("Wrote encryption and relay secrets to netbird-server.env")
PY
```

Copy those values into `config.yaml`:

- `server.store.encryptionKey` ← `NETBIRD_ENCRYPTION_KEY`
- `server.authSecret` ← `NETBIRD_RELAY_AUTH_SECRET`

Set `server.exposedAddress` to an address **containers can dial**. `localhost`
is fine for host tools and the dashboard; mitmproxy inside Docker cannot use
it. Use your Docker host LAN IP (for example `http://192.168.5.2:33073`).

## 2. Start the stack

```bash
docker compose --env-file netbird-server.env up -d
```

Always pass `--env-file netbird-server.env`.

## 3. Verify the API

```bash
curl -s http://localhost:33073/api/instance
```

Expect `"setup_required": true` before bootstrap. Use **http** (not https) and
the **/api/** prefix.

## 4. Bootstrap the first admin

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

## 5. Open the dashboard

```text
http://localhost:8080
```

Or the setup wizard: `http://localhost:8080/setup` (before step 4). Create a
**Setup Key** for peer enrollment.

## 6. Point sandcat at the server

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

Replace `192.168.5.2` with your Docker host IP (`colima status -j` on Colima).
`server.exposedAddress` in `config.yaml` must match the enrollment URL or
peers dial `localhost` / `[::1]` inside the container. Recreate the server
after changing it:

```bash
docker compose --env-file netbird-server.env up -d --force-recreate netbird-server
```

Then recreate mitmproxy (`sandcat run --force-recreate mitmproxy`).

## Troubleshooting

### Peers dial `[::1]:33073` after enrollment

The management server is still advertising `http://localhost:33073` in
`config.yaml` `server.exposedAddress`. Set it (and
`netbird_enrollment_management_url`) to your Docker host IP, recreate
netbird-server, then recreate mitmproxy.

### Port clash

Default ports **8080** (dashboard) and **33073** (management API) may already
be in use. Change `NETBIRD_DASHBOARD_HTTP_PORT` and `NETBIRD_MGMT_API_PORT` in
`netbird-server.env`, then update `config.yaml` and `dashboard.env` URLs to
match.

### `curl: (52) Empty reply` or SSL errors on port 33073

- Use **`http://localhost:33073/api/...`** — not `https://` and not `/setup`
  (dashboard route; API is `/api/setup`).
- Ensure compose maps **`33073:80`** to `netbird-server`, not `33073:443`.
- Recreate after config changes:
  `docker compose --env-file netbird-server.env up -d --force-recreate netbird-server`

### `/api/setup` returns "not authenticated"

Embedded IdP must be enabled in `config.yaml` (`server.auth.issuer`). If
needed, reset data:

```bash
docker compose --env-file netbird-server.env down -v
docker compose --env-file netbird-server.env up -d
```
