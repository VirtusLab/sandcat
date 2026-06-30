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
Removing reachability by deleting a NetBird peer or route, causing `wg-client` to drop the WireGuard route via `wg syncconf`.

_Avoid_: network kill switch (too vague)

**Logical Revocation**:
Runtime catalog transition to `Revoked` — capability disappears from the bundle regardless of physical path.

**Network Binding**:
The link between a network capability and concrete NetBird identifiers (`peer_id`, `network` CIDR, optional `route_id`).

## Relationships

- A **Capability Bundle** includes zero or more network capabilities when their lifecycle state is Visible or Leased
- Each network capability has exactly one **Network Binding**
- **Logical Revocation** triggers **Physical Revocation** via `NetBirdRevocationBackend` (`disable_binding` by default; `peer_remove` when catalog `sync_mode` requires)
- **Logical Grant (lease)** triggers **Physical Enable** via `grant_binding` → `enable_binding`
- **Physical Revocation** outside the runtime triggers **Logical Revocation** via `RouteDisappearanceWatcher`

## Example dialogue

> **Dev:** "When the agent's `reach_api` lease expires, does the route disappear?"
> **Domain expert:** "Only if revocation or expiry also drives **Logical Revocation**, which then calls NetBird to remove the peer/route. Expiry alone today returns the capability to Visible or Declared per base policy — physical removal is explicit."

**Capability Control Plane**:
The trusted process that owns `CapabilityRuntime` state, NetBird revocation credentials, and the route watcher. Runs in a dedicated compose sidecar (`capability-runtime` service), not inside the agent or `wg-client`.

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

## Flagged ambiguities

- NetBird **implementation** runs inside `wg-client` (`wt0` overlay); the original plan described a separate `netbird` sync sidecar for `wg0` — these are different layers.
- Phase 3b plan is formal and **implemented** (Tasks 1–8): `docs/superpowers/plans/2026-06-23-capability-sandcat-phase3b.md`.
- Phase 3c NetBird policy sync is **implemented** — supersedes the deprecated L7 policy design.
- **DEPRECATED:** `docs/superpowers/specs/2026-06-23-capability-dynamic-l7-policy-phase3c-design.md` — per-request mitmproxy L7 allowlist from bundle; replaced by NetBird policy sync spec above.
- Phase 4 is a **DRAFT spec** only (not approved for implementation): `docs/superpowers/specs/2026-06-23-capability-comparative-evaluation-phase4-design.md`.
