# capability-runtime

Phase 0+1+3 proof-of-concept for [capability-oriented networking](../../docs/superpowers/specs/2026-06-15-capability-oriented-networking-design.md).

Implements the v1 `CapabilityRuntime` protocol: dynamic capability bundles, leased tools, revocation, observability with replay, an `AgentExecutionLoop` harness with optimistic check-then-act, and Phase 3 network reachability as a first-class capability.

## Spec thesis: Reachability == Capability

The design spec states that **reachability is capability**: an agent only has a network route when the runtime grants it in the current `CapabilityBundle`. Network endpoints are not ambient permissions — they appear after lease (or visibility grant) and disappear on revoke or physical route loss, with the same lifecycle semantics as leased tools.

Phase 3 realizes this thesis by binding each network capability to a NetBird peer/route (`NetworkBinding`) and keeping logical runtime state aligned with physical WireGuard reachability.

## Scope

**In scope (Phase 0+1):**

- `check_current_capabilities`, `request_capability_lease`, `revoke_capability`, `discover_capabilities`
- JSONL execution/capability event tracing with seed-gated replay
- PoC 1: `create_pr` (quota=1, ttl=10m)
- PoC 2: mock MCP `write_note` (quota=3, ttl=5m)

**In scope (Phase 3 — networking realization):**

- Network capabilities in `CapabilityBundle.networks` with `NetworkBinding` (peer, route, CIDR)
- **Logical revoke → physical:** `revoke_capability(ref, reason)` calls `NetBirdRevocationBackend` to remove peer/route via injectable `NetBirdClient`, then performs logical catalog revocation
- **Physical disappearance → logical revoke:** `RouteDisappearanceWatcher` polls NetBird peer state; when a bound peer vanishes (e.g. after external `wg syncconf`), calls `runtime.revoke_from_physical()` — logical-only, no duplicate NetBird API call
- PoC 3: `reach_api` network route lifecycle demo
- Observability events with `physical_revocation` and `physical_trigger` flags

**In scope (Phase 3b — sandcat sidecar integration):**

- `capability-runtime` compose sidecar: daemon, dual Unix socket RPC, route watcher, settings-backed `RestNetBirdClient`
- **Agent surface** (`agent.sock`): `capability.check`, `capability.lease`, `capability.discover` only
- **Admin surface** (`admin.sock`): agent methods plus `capability.revoke`, `capability.watch.poll`
- **MCP bridge** (`capability-mcp-bridge`): stdio MCP in agent container → JSON-RPC over `agent.sock`
- Fixed `SANDCAT_AGENT_ID` per devcontainer; bridge injects identity — agent-supplied `agent_id` ignored
- Operator CLI: `sandcat capability` via `docker compose exec capability-runtime`
- Catalog loaded at sidecar startup from `CAPABILITY_CATALOG_JSON` — no `register_*` over RPC

**In scope (Phase 3c — NetBird policy sync):**

- **Grant sync on lease:** `request_capability_lease` calls `NetBirdClient.enable_binding()` via `grant_binding` when the capability has a `NetworkBinding`
- **Revoke sync on revoke / quota / TTL:** `revoke_capability` and lease exhaustion call `disable_binding()` — default `sync_mode=route_enable` disables the route and keeps the peer enrolled
- **`sync_mode` on `NetworkBinding`:** `route_enable` (default), `acl_policy` (stub), `peer_remove` (Phase 3 break-glass — deletes peer on revoke)
- Grant failure rolls back the lease (fail closed); observability emits `physical_sync: enabled` on successful network lease
- mitmproxy remains egress inspection only — no per-request L7 allowlist from bundle

**In scope (Phase 3e — proxy-peer gateway):**

- Catalog `lease_policy` on network capabilities overrides PoC hardcoded quotas in `request_capability_lease`
- Admin-only `capability.l7.record` RPC decrements network lease quota from post-hoc mitmproxy flow records
- `l7_record.py` matches flow host to active network binding CIDR and calls `record_action`
- mitmproxy addon emits `l7_flow` events when `CAPABILITY_L7_RECORD=1` (best-effort Unix socket to admin surface)

**Out of scope / known limitations:**

- Token budget enforcement (`token_budget` is stored but not decremented)
- In-flight revocation policy (`allow_finish` / `interrupt`) — pre-action stale bundles fail closed; mid-action policy not implemented
- `TaskContext`-driven visibility rules
- Non-tool capability kinds (`rules`, `skills`, etc.) in bundles
- Multi-agent leasing on the same capability (global `LEASED` catalog state)
- Full NetBird ACL/group API (`acl_policy` sync_mode is stubbed)
- MCP workload gateway, host-published HTTP RPC (Phase 3d+)

## NetBird bridge (logical ↔ physical)

Phase 3 connects the capability runtime to the sandcat NetBird deployment model described in [NetBird dynamic WireGuard plan](../../docs/superpowers/plans/2026-06-15-netbird-dynamic-wireguard.md). Phase 3c adds bidirectional sync on grant and revoke via `enable_binding` / `disable_binding`.

```
Grant (lease)                     Physical path (sandcat)
─────────────                     ───────────────────────
request_capability_lease(ref)
  → grant_network_binding
      → enable_binding(sync_mode)    → NetBird management API
  → catalog LEASED                      → route enabled / created
  → emit physical_sync: enabled         → mitmproxy: route on wt0
        │                                 (agent traffic: wg0 → mitmproxy L7
        │  (on enable_binding failure:       → wt0 → mesh peer)
        │   rollback lease, revert catalog)
        ▼

Logical revoke (runtime)          Physical path (sandcat)
─────────────────────────         ───────────────────────
revoke_capability(ref, reason)
  → NetBirdRevocationBackend
      → disable_binding(sync_mode)   → NetBird management API
  → catalog REVOKED                     → route disabled (default)
  → emit physical_revocation            → mitmproxy drops route on wt0
                                        → peer remains enrolled (route_enable)
```

When revocation originates from the runtime, `NetBirdRevocationBackend.revoke_binding()` calls `disable_binding()` through the injected `NetBirdClient`. Default `sync_mode=route_enable` disables the route but keeps the peer — the agent loses routing without unenrolling the mesh peer. Set `sync_mode=peer_remove` in the catalog for Phase 3 break-glass behavior (delete peer on revoke).

## RouteDisappearanceWatcher (physical → logical)

The reverse path handles external physical removal (management server change, `wg syncconf`, operator `peer remove`):

```
Physical disappearance              Logical reconcile (runtime)
──────────────────────              ───────────────────────────
peer/route gone from NetBird
  (mitmproxy wt0 route disappears)
        │
        ▼
RouteDisappearanceWatcher.poll_once()
  → peer_exists(binding.peer_id) == false
  → runtime.revoke_from_physical(binding, reason)
  → catalog REVOKED (no NetBird API call)
  → emit physical_trigger: true
```

The watcher ensures the runtime catalog stays consistent when reachability disappears outside the runtime — the spec's physical `Revoked` trigger (Phase 3 / idea7). In watcher JSONL events, `physical_trigger` is an alias for the spec's `physical_revocation_reconciled` flag.

**Peer identity:** `binding.peer_id` refers to the **mitmproxy** NetBird peer (hostname `sandcat-proxy`), not `wg-client`. Routes are managed on mitmproxy's `wt0` interface. wg-client has no NetBird enrollment and no `wt0` interface.

## Sidecar architecture (Phase 3b)

```
┌──────────────────────── agent container ────────────────────────┐
│  Cursor / Claude agent                                          │
│       │ stdio MCP                                               │
│       ▼                                                         │
│  capability-mcp-bridge  ──JSON-RPC──►  agent.sock (ro volume)   │
│  (SANDCAT_AGENT_ID injected)                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                    capability-socket volume
                              │
┌──────────────────────── capability-runtime sidecar ───────────┐
│  CapabilityRuntime + RouteDisappearanceWatcher                  │
│  RestNetBirdClient ← settings.json (netbird_api_token)          │
│       │                              │                          │
│  agent.sock (check/lease/discover)   admin.sock (revoke/watch)  │
└─────────────────────────────────────────────────────────────────┘
                              │
                    operator: sandcat capability
                    (docker compose exec → admin.sock)
```

The agent container mounts `capability-socket:/run/sandcat-capability:ro` (separate from read-only `wg-runtime:/run/sandcat`) and receives `CAPABILITY_AGENT_SOCKET` plus `SANDCAT_AGENT_ID`. It does **not** mount `admin.sock` write access, does **not** receive `NB_API_TOKEN`, and does **not** import `CapabilityRuntime`. NetBird credentials live only in the sidecar via read-only `settings.json`.

Cursor MCP config (`.cursor/mcp.json` in devcontainer):

```json
{
  "mcpServers": {
    "sandcat-capability": {
      "command": "capability-mcp-bridge",
      "args": []
    }
  }
}
```

MCP meta-tools (`capability_check`, `capability_lease`, `capability_discover`) map to the agent RPC surface. Workload tools (`write_note`, `create_pr`, etc.) remain separate MCP servers gated by bundle visibility.

## Security (Phase 0+1 + 3b)

Mutating APIs require `caller` to match the lease-bound `agent_id` (`CallerIdentityMismatch` on impersonation). Leased tool execution is serialized per `lease_id` in `AgentExecutionLoop` to prevent quota races. Observability events are runtime-authored (`source: runtime`) or agent-loop-bound (`source: agent_loop` with enforced `agent_id`); public `emit_*` APIs are not exposed on `CapabilityRuntime`.

**Phase 3b boundary:**

| Surface | Socket | Methods | Who |
|---------|--------|---------|-----|
| Agent | `agent.sock` | check, lease, discover | MCP bridge in agent container |
| Admin | `admin.sock` | check, lease, discover, revoke, watch.poll | `sandcat capability` operator CLI |

- `capability.revoke` requires `caller=operator` on the runtime — agents cannot self-revoke or revoke others
- RPC dispatcher allowlists reject unknown methods and admin-only methods on the agent socket
- `agent_id` in RPC/MCP params is overwritten with `SANDCAT_AGENT_ID` on the agent surface
- Catalog registration happens at sidecar startup only — not over RPC

**Not yet addressed:** cryptographic trace signing, network-authenticated control plane, cross-process cryptographic auth (Unix permissions + container split sufficient for 3b), and replacing the Python-based agent MCP bridge with a native binary to remove Python from non-Python agent images.

## Quick start

```bash
cd capability-runtime
pytest -q --ignore=tests/test_security.py --ignore=tests/test_policy.py
PYTHONPATH=src:. python poc/create_pr_demo.py
PYTHONPATH=src:. python poc/mcp_tool_demo.py
PYTHONPATH=src:. python poc/network_route_demo.py
```

## Engineering gate (Phase 3c)

Automated unit tests and PoC demo, plus printed manual live-smoke steps (NetBird enrollment required):

```bash
bash scripts/phase3c_engineering_gate.sh
bash scripts/phase3e_engineering_gate.sh
```

Manual steps map to the [Phase 3c spec §11 success criteria](../../docs/superpowers/specs/2026-06-30-capability-netbird-policy-sync-phase3c-design.md#11-success-criteria-engineering-gate-before-phase-4) and [Phase 3e spec §9](../../docs/superpowers/specs/2026-07-08-capability-proxy-peer-gateway-phase3e-design.md). For catalog ID setup before live smoke, see [Catalog IDs for live smoke](../../cli/README.md#catalog-ids-for-live-smoke) in the CLI README.

## Layout

| Module | Role |
|--------|------|
| `runtime.py` | Protocol surfaces, bundle assembly, NetBird backend wiring |
| `catalog.py` | Lifecycle states, network binding storage |
| `network.py` | `NetworkBinding`, `PhysicalRevocationBackend` protocol |
| `netbird_client.py` | `NetBirdClient` protocol, mock and REST implementations |
| `netbird_backend.py` | `NetBirdRevocationBackend` — grant/revoke via `enable_binding` / `disable_binding` |
| `netbird_sync.py` | Grant/revoke orchestration helpers for network bindings |
| `route_watcher.py` | `RouteDisappearanceWatcher` — physical disappearance → logical revoke |
| `lease.py` / `revoke.py` | Grant, quota, revocation |
| `policy.py` | Lease parameters (PoC defaults + catalog `lease_policy` registration) |
| `l7_record.py` | Post-hoc L7 flow → network lease quota decrement |
| `observability.py` | JSONL trace + replay |
| `agent_loop.py` | Check-then-act harness |
| `mcp_adapter.py` | Transport-agnostic MCP tool wrapper |
| `daemon.py` | Sidecar main: runtime, watcher, dual Unix sockets |
| `rpc/dispatcher.py` | JSON-RPC routing with agent/admin allowlists |
| `rpc/transports/unix.py` | AF_UNIX JSON-RPC server/client |
| `mcp/server.py` | Minimal MCP meta-tools server |
| `mcp/bridge.py` | Stdio MCP ↔ agent.sock forwarder |
| `settings.py` | Sandcat settings JSON layers for NetBird tokens |
| `cli.py` | Operator admin-socket CLI (used by `sandcat capability`) |
