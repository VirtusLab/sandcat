# Proxy-peer gateway (manual)

Sandcat does not create a proxy-peer container. This example is a small
NetBird-enrolled HTTP service (`GET /hello` on port 8080) you can run beside
a sandcat project and target from **capability-runtime** via `dns_label`.

It is not part of `sandcat init`. Keep capability-runtime and mitmproxy
enrollment (`--netbird --capability`); add this gateway yourself if you need
a mesh destination to lease.

## Prerequisites

- A running NetBird management server (cloud, or [../netbird-server](../netbird-server/))
- `sandcat init --netbird --capability` already done for the project
- `netbird_enrollment_key` and `netbird_api_token` in
  `~/.config/sandcat/settings.json`

## 1. Start the gateway

From this directory:

```bash
export NB_SETUP_KEY='<setup-key>'
export NB_MANAGEMENT_URL='http://192.168.5.2:33073'   # container-reachable
export NB_API_TOKEN='<personal-access-token>'

docker compose --env-file netbird.env -f compose-proxy-peer.yml up -d --build
```

Compose defaults `NB_PEER_NAME` to `proxy-peer`. That hostname is the NetBird
peer name and the `dns_label` prefix (`proxy-peer.netbird.selfhosted` on the
default self-hosted domain). It will not collide with the mitmproxy peer
(`{project}-proxy`). Override `NB_PEER_NAME` only if you also change
`dns_label` and the Layer 1 host to match.

## 2. Confirm enrollment

```bash
sandcat netbird status
```

You should see a peer named `proxy-peer` (FQDN
`proxy-peer.netbird.selfhosted` on a default self-hosted domain).

## 3. Layer 1 allow rule

Merge [settings-proxy-peer.json](settings-proxy-peer.json) into the project's
`.sandcat/settings.json`. The Layer 1 host is already
`proxy-peer.netbird.selfhosted`.

Reload mitmproxy (`sandcat restart-proxy`) so the rule is live.

## 4. Catalog network capability

The default catalog from `sandcat init --capability` stays small (`create_pr`
plus mitmproxy `reach_api`). Merge the `reach_proxy` entry from
[capability-catalog.json](capability-catalog.json) into the project's
`.devcontainer/sandcat/capability-catalog.json`.

`dns_label` is `proxy-peer.netbird.selfhosted`. capability-runtime resolves
`peer_id` and mesh IP at lease time, so the catalog survives gateway
recreates.

Restart the capability sidecar after editing the catalog, then:

```bash
sandcat capability lease --ref cap-reach-proxy --justification "need gateway access"
```

From the agent network, `GET http://proxy-peer.netbird.selfhosted:8080/hello`
should succeed while the lease is held and fail after revoke.

## Layout

| File | Role |
|------|------|
| `Dockerfile.proxy-peer` | Debian image with pinned NetBird client |
| `compose-proxy-peer.yml` | Standalone compose service |
| `netbird.env` | Client version + checksums (same pin as sandcat mitmproxy) |
| `scripts/proxy-peer-init.sh` | Enroll + run hello server |
| `scripts/proxy-peer-hello.py` | `GET /hello` |
| `scripts/netbird-peer-lifecycle.sh` | Shared enroll/replace/dns_label helpers |
| `settings-proxy-peer.json` | Layer 1 allow-list example |
| `capability-catalog.json` | Gateway network capability to merge into the project catalog |
