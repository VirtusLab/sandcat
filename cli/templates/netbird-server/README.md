# NetBird local self-hosted template

Provisioned by `sandcat init --netbird --netbird-server new` into
`~/.config/sandcat/netbird-server/`.

Uses the **combined** `netbirdio/netbird-server` image (management + signal +
relay + STUN) — the same layout as NetBird's
[getting-started.sh](https://docs.netbird.io/selfhosted/selfhosted-quickstart#installation-script)
exposed-ports mode, tuned for localhost.

For a VM with a public domain, use `sandcat init --netbird --netbird-server quickstart`
instead (see `cli/README.md`).

## 1. Start the stack

```bash
cd ~/.config/sandcat/netbird-server
docker compose --env-file netbird-server.env up -d
```

Always pass `--env-file netbird-server.env`.

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

Or the setup wizard: `http://localhost:8080/setup` (before step 3).

## 5. Wire sandcat

Host tools and the browser use `localhost`. wg-client needs the Docker host IP
(see [cli/README.md](../../README.md#local-self-hosted-sandcat-template)):

```json
"netbird_management_url": "http://localhost:33073",
"netbird_enrollment_management_url": "http://192.168.5.2:33073",
"netbird_enrollment_key": "<setup-key from dashboard>",
"netbird_api_token": "<pat from /api/setup or dashboard>"
```

Replace `192.168.5.2` with your Docker host IP (`colima status -j` on Colima).
Then restart **both** netbird-server and wg-client (server `exposedAddress` must match
the enrollment URL or peers dial `localhost` / `[::1]` inside the container):

```bash
cd ~/.config/sandcat/netbird-server
docker compose --env-file netbird-server.env up -d --force-recreate netbird-server
sandcat run --force-recreate wg-client
```

## Troubleshooting

### wg-client dials `[::1]:33073` after enrollment

The management server was still advertising `http://localhost:33073` in
`config.yaml` `server.exposedAddress`. Set `netbird_enrollment_management_url` to your
Docker host IP, run `sandcat init` or `sandcat run` once (syncs `exposedAddress`), then
restart netbird-server and recreate wg-client as above.

### Port clash with sandcat devcontainers

The default ports **8080** (dashboard) and **33073** (management API) may
already be in use on your machine — for example if a sandcat devcontainer or
another stack publishes them. Change `NETBIRD_DASHBOARD_HTTP_PORT` and
`NETBIRD_MGMT_API_PORT` in `netbird-server.env`, then re-run
`sandcat init --netbird --netbird-server new` (after removing the old
provisioned directory) so `config.yaml` and `dashboard.env` pick up the new URLs.

### `curl: (52) Empty reply` or SSL errors on port 33073

- Use **`http://localhost:33073/api/...`** — not `https://` and not `/setup`
  (dashboard route; API is `/api/setup`).
- Ensure compose maps **`33073:80`** to `netbird-server`, not `33073:443`.
- Recreate after template changes:
  `docker compose --env-file netbird-server.env up -d --force-recreate netbird-server`

### `/api/setup` returns "not authenticated"

Embedded IdP must be enabled in `config.yaml` (`server.auth.issuer`). Re-provision
or merge the updated template, then restart. If needed, reset data:

```bash
docker compose --env-file netbird-server.env down -v
docker compose --env-file netbird-server.env up -d
```

### Already provisioned an older copy

Sandcat skips re-copying when `~/.config/sandcat/netbird-server` exists. Remove
it and run `sandcat init --netbird --netbird-server new` again, or manually
replace `docker-compose.yml`, `config.yaml`, and `dashboard.env` from this
template.

Secrets (`NETBIRD_ENCRYPTION_KEY`, relay `authSecret`) are generated once at
first provision. Keep them stable across restarts.
