# NetBird self-hosted template

This directory is provisioned by `sandcat init --netbird --netbird-server new`.
It is a starter skeleton, not a ready-to-run production config.

Before first startup, review and adapt:

- `netbird-server.env` (image/version pins and required endpoint/auth env values)
- `management.json` (mounted by compose into management service)
- `turnserver.conf` (mounted by compose into coturn; set credentials/realm)

Start with:

```bash
docker compose --env-file netbird-server.env up -d
```
