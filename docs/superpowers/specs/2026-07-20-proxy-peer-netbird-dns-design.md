# Proxy-Peer NetBird DNS Targeting — Design Spec

> **Date:** 2026-07-20
> **Status:** DRAFT
> **Scope:** Amendment to [Phase 3e](./2026-07-08-capability-proxy-peer-gateway-phase3e-design.md). Stop forcing operators to update hardcoded mesh IPs in `capability-catalog.json` and Layer 1 settings after every proxy-peer container recreate.

**Parent:** [Phase 3e — Proxy-Peer Gateway](./2026-07-08-capability-proxy-peer-gateway-phase3e-design.md)

**Plan:** [Proxy-Peer NetBird DNS Targeting Plan](../plans/2026-07-20-proxy-peer-netbird-dns.md)

---

## 1. Problem

Phase 3e requires the operator to manually update three files after recreating the `proxy-peer` container:

| File | What changes | Why |
|------|-------------|-----|
| `capability-catalog.json` | `peer_id` + `network` IP | New container = new NetBird enrollment |
| `.sandcat/settings.json` | `host` IP in network allow rule | Layer 1 mitm allowlist keys on IP |
| Engineering gate smoke curl | Target IP in curl URL | Manual step in gate script |

Each recreate produces a new peer ID and a new mesh IP, breaking all three locations simultaneously. This is a PoC-level pain that surfaces immediately during development (container rebuild, `--force-recreate`, `up --build`).

---

## 2. Root causes

1. **NetBird peer identity is container-ephemeral.** `/var/lib/netbird` is not persisted across container recreates, so each `netbird up` registers a fresh peer with a new ID and a new IP assignment from the mesh CIDR pool.
2. **Catalog stores physical `peer_id`/`network` directly.** There is no layer of indirection to a stable name.
3. **Layer 1 template uses literal IP.** `settings-proxy-peer.json` has `REPLACE_PROXY_PEER_MESH_IP` which is then pasted literally into settings — no stable hostname.

---

## 3. Decision: hostname-first, IP-physical

Physical NetBird routes remain `route_enable` on `<mesh-ip>/32` — the Routes API is CIDR-based and that does not change.

**New indirection layer:** the operator sets a stable `dns_label` in the catalog (matching the NetBird peer name, which is set at enrollment time and does not change on recreate if the same hostname/`--name` is used). At lease time, capability-runtime resolves `dns_label` → current `peer_id` + mesh IP via the NetBird peers API, then calls `enable_binding` with the resolved values.

**Agent DNS:** wg-client dnsmasq is extended to forward the NetBird mesh domain (`netbird.selfhosted` or the configured domain) to NetBird's internal nameserver when available. The agent can then `curl http://peer-proxy.netbird.selfhosted:8080/hello` and the FQDN resolves to the current mesh IP without operator intervention.

**Layer 1 mitm:** `settings-proxy-peer.json` switches from a literal IP placeholder to `peer-proxy.netbird.selfhosted`. The mitmproxy addon already uses `fnmatch` host matching, so this requires no addon changes — just the settings value.

**Fallback:** IP-only mode remains fully supported. If `dns_label` is absent, behavior is identical to Phase 3e today. If NetBird DNS is not enabled, the operator falls back to editing IPs as before.

---

## 4. Catalog schema extension

```json
{
  "ref": "cap-reach-proxy",
  "type": "network",
  "dns_label": "peer-proxy.netbird.selfhosted",
  "peer_id": "peer-placeholder",
  "network": "0.0.0.0/32",
  "sync_mode": "route_enable",
  "proxy": {"port": 8080, "path_prefix": "/hello"},
  "lease_policy": {"quota": 5, "ttl_minutes": 15, "token_budget": 10000}
}
```

| Field | When `dns_label` set | When not set |
|-------|---------------------|--------------|
| `dns_label` | Stable NetBird peer name (FQDN or hostname) | Absent |
| `peer_id` | Any placeholder; overwritten at resolve | Real peer ID (Phase 3e behavior) |
| `network` | Any placeholder CIDR; overwritten at resolve | Real mesh `/32` (Phase 3e behavior) |

Resolution rules:
- Exact match on `dns_label` field of NetBird peer.
- Prefix match: if label contains no dot, match peers whose `dns_label` starts with `<label>.`.
- If no peer found at lease time: raise `PeerResolutionError`; lease fails with clear message.

---

## 5. wg-client dnsmasq NetBird domain forward

wg-client runs dnsmasq for split-DNS. The `write_dnsmasq_conf` function in `wg-client-init.sh` is extended:

After `start_netbird` completes, a helper `netbird_dns_nameserver_ip` queries `netbird status --json` (or `netbird status`) for the nameserver IP published by the management server. If found and non-empty, a domain-scoped forward is prepended to the dnsmasq config before the catch-all upstream:

```text
server=/netbird.selfhosted/<nameserver-ip>
```

dnsmasq is reloaded (SIGHUP or conf rewrite + restart via existing `supervise_dnsmasq` loop).

If `Nameservers: 0/0` (NetBird DNS not enabled in dashboard), the domain line is omitted and a one-line log is emitted. IP-only mode is unchanged.

**Dashboard prerequisite (one-time):** Enable DNS / Nameservers for group **All** in the NetBird dashboard. This publishes a nameserver to enrolled peers.

---

## 6. Layer 1 settings template

`cli/templates/settings-proxy-peer.json` changes from:

```json
{"host": "REPLACE_PROXY_PEER_MESH_IP", "port": 8080}
```

to:

```json
{"host": "peer-proxy.netbird.selfhosted", "port": 8080}
```

The mitmproxy addon resolves the `host` field via `fnmatch` matching, which already handles bare hostnames and wildcards. No addon changes required.

---

## 7. Success criteria

- `sandcat capability lease --ref cap-reach-proxy` succeeds with `dns_label` catalog, resolves peer ID + mesh IP, enables route.
- `sandcat run curl http://peer-proxy.netbird.selfhosted:8080/hello` returns hello JSON after lease **without any operator IP edits** following proxy-peer recreate (same NetBird peer name must be kept stable).
- IP-only path (Phase 3e): no change; `peer_id`/`network` without `dns_label` continues to work.
- `netbird status` shows `Nameservers: 1/1` after dashboard DNS enabled; `getent hosts peer-proxy.netbird.selfhosted` resolves on wg-client.
- Phase 3e revoke/quota/TTL behavior unchanged.

---

## 8. Non-goals

- Persistent `/var/lib/netbird` volumes (stable peer_id across recreate) — separate follow-up.
- Automatic NetBird ACL policy creation on lease.
- NetBird domain-routes API (routes stay CIDR/IP).
- Rewriting `supervise_netbird_daemon` `|| true` error suppression.
- Mesh connectivity fix (`Peers 0/1 Connected`) — DNS does not fix ACL/relay.

---

## 9. Relationship to other phases

| Phase | Relationship |
|-------|-------------|
| 3e | **Parent** — this spec is an ergonomics amendment; two-layer model unchanged |
| 3f (future) | NetBird Networks deny-by-default; may supersede `route_enable` |
| 4 | Smoke tests (E7) can use FQDN once DNS forward is wired |
