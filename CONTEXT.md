# Sandcat Capability Networking

Capability-oriented networking for autonomous agents in sandcat devcontainers. Agents reason only from their current `CapabilityBundle`; reachability to network endpoints is a leased/revocable capability, not ambient permission.

## Language

**Capability Runtime**:
The authoritative control plane that owns catalog state, leases, revocations, and observability. Issues `CapabilityBundle` snapshots to agents.

_Avoid_: capability library, agent runtime (when meaning the control plane)

**Capability Bundle**:
The typed snapshot of what an agent may use right now — tools, network routes, budgets — returned by `check_current_capabilities`.

_Avoid_: permission set, tool list

**Phase 3 (Networking Realization)**:
Python `capability-runtime/` bridge proving `Reachability == Capability`: logical revoke removes NetBird peer/route; physical route disappearance reconciles back into runtime state.

_Avoid_: NetBird CLI work (that is a separate sandcat track)

**Phase 3b (Sandcat Integration)**:
Compose sidecar wiring: `capability-runtime` service, Capability MCP for agents, `sandcat capability` for operators. **Implemented** — plan: `docs/superpowers/plans/2026-06-23-capability-sandcat-phase3b.md`.

_Avoid_: Phase 4

**Phase 3c (NetBird Policy Sync)**:
On lease grant/revoke, `CapabilityRuntime` synchronizes NetBird physical bindings (routes, future ACL) via `enable_binding` / `disable_binding`. Default revoke disables the route and keeps the peer. mitmproxy remains egress inspection only. **Spec:** `docs/superpowers/specs/2026-06-30-capability-netbird-policy-sync-phase3c-design.md`. Plan: `docs/superpowers/plans/2026-06-30-capability-netbird-policy-sync-phase3c.md`.

_Avoid_: conflating with Phase 3b sidecar work; per-request mitmproxy L7 allowlist (see deprecated spec below)

**Phase 4 (Comparative Evaluation)**:
Controlled experiments baseline vs treatment; metrics and ablations. **DRAFT spec:** `docs/superpowers/specs/2026-06-23-capability-comparative-evaluation-phase4-design.md`. Does not implement new enforcement — measures Phases 0–3c.

**Physical Revocation**:
Removing reachability by deleting a NetBird peer or route, causing `mitmproxy` to drop the WireGuard route on `wt0` via the NetBird daemon.

_Avoid_: network kill switch (too vague)

**Logical Revocation**:
Runtime catalog transition to `Revoked` — capability disappears from the bundle regardless of physical path.

**Network Binding**:
The link between a network capability and concrete NetBird identifiers (`peer_id`, `network` CIDR, optional `route_id`, optional `dns_label`). When `dns_label` is set (e.g. `{project}-proxy-peer.netbird.selfhosted`), capability-runtime resolves the current `peer_id` and mesh IP from the NetBird peers API at lease time, so catalog entries survive proxy-peer container recreates without manual IP edits. See [NetBird DNS Targeting spec](docs/superpowers/specs/2026-07-20-proxy-peer-netbird-dns-design.md).

## Relationships

- A **Capability Bundle** includes zero or more network capabilities when their lifecycle state is Visible or Leased
- Each network capability has exactly one **Network Binding**
- **Logical Revocation** triggers **Physical Revocation** via `NetBirdRevocationBackend` (`disable_binding` by default; `peer_remove` when catalog `sync_mode` requires)
- **Logical Grant (lease)** triggers **Physical Enable** via `grant_binding` → `enable_binding`
- **Physical Revocation** outside the runtime triggers **Logical Revocation** via `RouteDisappearanceWatcher`
- **Logical Revocation** triggers an **L7 Revocation Push** to mitmproxy carrying the host patterns from the **Network Binding** and the capability's **Revocation Close Policy**
- Each network capability in the catalog has at most one **Revocation Close Policy**; if absent, `drain_deadline` (30s) is the default
- **Network Rule Enable Flag** is evaluated before **L7 Revocation Push** — a statically disabled rule blocks traffic regardless of runtime lease state

## Example dialogue

> **Dev:** "When the agent's `reach_api` lease expires, does the route disappear?"
> **Domain expert:** "Only if revocation or expiry also drives **Logical Revocation**, which then calls NetBird to remove the peer/route. Expiry alone today returns the capability to Visible or Declared per base policy — physical removal is explicit."

**Capability Control Plane**:
The trusted process that owns `CapabilityRuntime` state, NetBird revocation credentials, and the route watcher. Runs in a dedicated compose sidecar (`capability-runtime` service), not inside the agent, `wg-client`, or `mitmproxy`.

_Avoid_: capability daemon (when meaning the agent), in-process runtime (PoC only)

**Capability RPC**:
Internal JSON-RPC 2.0 dispatcher inside the capability sidecar. Used for operator CLI (`sandcat capability` via exec) and tests. Not the primary agent-facing protocol.

_Avoid_: exposing revoke/register on this surface

**Capability MCP**:
MCP server exposed by the capability sidecar to the agent. Meta-tools: `capability_check`, `capability_lease`, `capability_discover`. Workload tools (`write_note`, `create_pr`, etc.) remain separate MCP servers gated by bundle visibility.

_Avoid_: using MCP for NetBird admin, conflating control-plane MCP with workload MCP

**Agent Identity**:
Opaque runtime-assigned id for the single agent in a devcontainer. Fixed as `SANDCAT_AGENT_ID` by compose; injected by the MCP bridge; not accepted from agent-supplied parameters.

_Avoid_: client-provided agent_id, multi-agent per container (Phase 3b)

> **Dev:** "Should the agent call the runtime over REST?"
> **Domain expert:** "No. The agent speaks **Capability MCP** for check/lease/discover. Work tools speak their own MCP servers. REST is only for NetBird management behind the trusted sidecar."

**L7 Revocation Push**:
The mechanism by which capability-runtime notifies mitmproxy of a revocation
event in real time. capability-runtime connects to a Unix socket exposed by
the mitmproxy addon and sends a typed revoke command carrying the host patterns
to close and the `RevocationClosePolicy` to apply. Replaces the previous
file-polling approach for zero-delay enforcement.

_Avoid_: policy refresh, rule reload, file sidecar (for this real-time path)

**Revocation Close Policy**:
A typed per-capability field (`immediate | drain | drain_deadline | deny_new`)
that controls how mitmproxy closes in-flight connections when the capability is
revoked. `immediate` = RST now; `drain` = complete in-flight response then
close; `drain_deadline` = drain up to N seconds then RST; `deny_new` = deny
new requests/streams, let existing ones finish. See ADR-0001.

_Avoid_: kill mode, close strategy, shutdown policy

**Mitmproxy Revocation Socket**:
The Unix socket file exposed by the mitmproxy addon inside the `mitmproxy-config`
shared volume, used exclusively by capability-runtime to push `L7 Revocation Push`
events. Not accessible to the agent or wg-client.

_Avoid_: mitmweb API (that is the UI surface, not this socket)

**Network Rule Enable Flag**:
An optional `"enabled": true|false` boolean on a `settings.json` network rule.
When `false`, the rule is skipped during policy evaluation as if it were absent,
without removing the rule definition from the file. Default when absent: `true`.
Distinct from `L7 Revocation Push` — this is a static config-time switch, not
a runtime revocation.

_Avoid_: rule toggle, runtime disable (use "L7 Revocation Push" for runtime)

## Flagged ambiguities

- NetBird **implementation** runs inside `mitmproxy` (`wt0` overlay); the original plan described a separate `netbird` sync sidecar for `wg0` — these are different layers. An earlier design had NetBird on `wg-client`, which caused a routing collision (WireGuard-in-WireGuard). The fix moves NetBird to mitmproxy so all traffic flows `wg0 → mitmproxy → internet or wt0 mesh` without a second WireGuard stack inside `wg-client`.
- Phase 3b plan is formal and **implemented** (Tasks 1–8): `docs/superpowers/plans/2026-06-23-capability-sandcat-phase3b.md`.
- Phase 3c NetBird policy sync is **implemented** — supersedes the deprecated L7 policy design.
- **DEPRECATED:** `docs/superpowers/specs/2026-06-23-capability-dynamic-l7-policy-phase3c-design.md` — per-request mitmproxy L7 allowlist from bundle; replaced by NetBird policy sync spec above.
- Phase 4 is a **DRAFT spec** only (not approved for implementation): `docs/superpowers/specs/2026-06-23-capability-comparative-evaluation-phase4-design.md`.
