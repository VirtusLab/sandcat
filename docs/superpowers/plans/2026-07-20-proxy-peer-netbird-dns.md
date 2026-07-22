# Proxy-Peer NetBird DNS Targeting Plan

**Spec:** [2026-07-20-proxy-peer-netbird-dns-design.md](../specs/2026-07-20-proxy-peer-netbird-dns-design.md)

**Status:** IMPLEMENTED — all tasks complete.

**Goal:** Stop forcing operators to update hardcoded mesh IPs in `capability-catalog.json` and Layer 1 settings after every proxy-peer container recreate by supporting stable NetBird FQDNs (e.g. `peer-proxy.netbird.selfhosted`).

---

## Tasks

### Task 0: Thin design spec ✅

- Created `docs/superpowers/specs/2026-07-20-proxy-peer-netbird-dns-design.md`
- Added Follow-up link in `docs/superpowers/specs/2026-07-08-capability-proxy-peer-gateway-phase3e-design.md`
- Commit: `docs(spec): add proxy-peer NetBird DNS targeting design`

### Task 1: Resolve peer by dns_label at lease (capability-runtime) ✅

**Files changed:**
- `capability-runtime/src/capability_runtime/network.py` — `NetworkBinding.dns_label: str | None = None`
- `capability-runtime/src/capability_runtime/errors.py` — `PeerResolutionError`
- `capability-runtime/src/capability_runtime/netbird_client.py` — `find_peer_by_dns_label`, `_resolve_dns_label`, wired into `enable_binding` for both `MockNetBirdClient` and `RestNetBirdClient`
- `capability-runtime/src/capability_runtime/daemon.py` — load `dns_label` from catalog
- `capability-runtime/tests/test_resolve_dns_label.py` — 7 tests (all green)
- `cli/templates/devcontainer/sandcat/capability-catalog.json` — `dns_label: "peer-proxy.netbird.selfhosted"` for `cap-reach-proxy`

Commit: `feat(capability-runtime): resolve network binding from NetBird dns_label`

### Task 2: wg-client dnsmasq NetBird domain forward ✅

**Files changed:**
- `cli/templates/devcontainer/sandcat/scripts/wg-client-init.sh` — `NETBIRD_DNS_DOMAIN` env var, `netbird_dns_nameserver_ip()`, `patch_dnsmasq_for_netbird()`, wired into `main()` after `start_netbird`
- `cli/test/wg-client/netbird_dns.bats` — 8 tests (all green)

Commit: `feat(wg-client): forward NetBird DNS domain via dnsmasq`

**Dashboard prerequisite (one-time):** Enable DNS / Nameservers for group **All** in the NetBird dashboard.

### Task 3: Layer 1 template + gate docs use FQDN ✅

**Files changed:**
- `cli/templates/settings-proxy-peer.json` — `host: "peer-proxy.netbird.selfhosted"`
- `capability-runtime/scripts/phase3e_engineering_gate.sh` — curl targets FQDN; IP fallback documented
- `cli/test/mitmproxy/settings_proxy_peer.bats` — updated expected host
- `cli/README.md` — Proxy-peer section updated with DNS-first workflow

Commit: `docs(cli): proxy-peer Layer 1 and gate prefer NetBird FQDN`

### Task 4: Engineering gate end-to-end note + CONTEXT link ✅

**Files changed:**
- `CONTEXT.md` — Network Binding entry updated with `dns_label` and link to spec
- `docs/superpowers/specs/2026-07-08-capability-proxy-peer-gateway-phase3e-design.md` — Goals §3 updated with FQDN reference
- `docs/superpowers/plans/2026-07-20-proxy-peer-netbird-dns.md` — this file

Commit: `docs: wire NetBird DNS targeting into CONTEXT and Phase 3e`

---

## Manual verification (operator)

1. **Dashboard:** DNS/nameservers enabled for All
2. **wg-client:** `netbird status` shows Nameservers ≠ 0/0; `getent hosts peer-proxy.netbird.selfhosted` resolves
3. Catalog uses `dns_label`; lease; `sandcat run curl http://peer-proxy.netbird.selfhosted:8080/hello`
4. Recreate proxy-peer **keeping same NetBird peer name** → no catalog IP edit (peer_id changes; resolver picks new id automatically)

---

## Risks (for reference)

- NetBird DNS disabled → FQDN never resolves; keep IP path as default and clear log when forward skipped
- Unstable `dns_label` on recreate (if hostname changes) — still need stable peer **name** in NetBird; volume persistence is a later phase
- Mesh still `0/1 Connected` → DNS irrelevant until ACL/relay fixed
