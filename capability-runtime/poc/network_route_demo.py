"""PoC 3 — network route reachability demo (spec Phase 3).

Runnable via:
  PYTHONPATH=src:. python poc/network_route_demo.py
  PYTHONPATH=src:. python -m poc.network_route_demo
"""

from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path
from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef, LeaseDecision


@dataclass
class DemoResult:
    initial_networks: list[str]
    lease_decision: LeaseDecision
    networks_after_lease: list[str]
    peer_id_after_lease: str | None
    peer_removed_by_revoke: bool
    networks_after_revoke: list[str]
    networks_after_external_removal: list[str]
    external_removal_peer_gone: bool


def _network_names(bundle) -> list[str]:
    return [n.name for n in bundle.networks]


def _peer_id_for(bundle, name: str) -> str | None:
    for cap in bundle.networks:
        if cap.name == name:
            return cap.peer_id
    return None


def _print_step(quiet: bool, step: int, message: str) -> None:
    if not quiet:
        print(f"Step {step}: {message}")


def run_poc3_demo(trace_path: Path, *, quiet: bool = False) -> DemoResult:
    """Execute the Phase 3 network route lifecycle and external disappearance."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24"}],
    )
    runtime = CapabilityRuntime(trace_path, "poc3-network-route", seed=42, netbird_client=client)
    watcher = RouteDisappearanceWatcher(runtime, client)
    agent = AgentIdentity("demo-agent")
    context: dict = {}
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")

    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)

    bundle1 = runtime.check_current_capabilities(agent, context)
    initial_networks = _network_names(bundle1)
    _print_step(
        quiet,
        1,
        f"check_current_capabilities → networks={initial_networks} (reach_api absent)",
    )

    decision = runtime.request_capability_lease(
        agent,
        ref,
        "Need API reachability for integration test",
    )
    _print_step(
        quiet,
        2,
        f"register + request_capability_lease → LeaseDecision(lease_id={decision.lease_id.value!r}, "
        f"quota={decision.quota}, token_budget={decision.token_budget}, "
        f"risk_envelope={decision.risk_envelope!r})",
    )

    bundle2 = runtime.check_current_capabilities(agent, context)
    networks_after_lease = _network_names(bundle2)
    peer_id = _peer_id_for(bundle2, "reach_api")
    _print_step(
        quiet,
        3,
        f"check_current_capabilities → networks={networks_after_lease} "
        f"(reach_api present, peer_id={peer_id!r})",
    )

    runtime.revoke_capability(ref, "security policy")
    peer_removed = not client.peer_exists("peer-abc")
    _print_step(
        quiet,
        4,
        f"revoke_capability → mock client peer removed (peer_exists={client.peer_exists('peer-abc')})",
    )

    bundle3 = runtime.check_current_capabilities(agent, context)
    networks_after_revoke = _network_names(bundle3)
    _print_step(
        quiet,
        5,
        f"check_current_capabilities → networks={networks_after_revoke} (reach_api absent)",
    )

    client._peers.append({"id": "peer-abc", "connected": True})
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    client.remove_peer("peer-abc")
    watcher.poll_once()
    bundle4 = runtime.check_current_capabilities(agent, context)
    networks_after_external = _network_names(bundle4)
    _print_step(
        quiet,
        6,
        f"re-register visible cap, external remove_peer + watcher.poll_once → "
        f"networks={networks_after_external} (reach_api absent)",
    )

    return DemoResult(
        initial_networks=initial_networks,
        lease_decision=decision,
        networks_after_lease=networks_after_lease,
        peer_id_after_lease=peer_id,
        peer_removed_by_revoke=peer_removed,
        networks_after_revoke=networks_after_revoke,
        networks_after_external_removal=networks_after_external,
        external_removal_peer_gone=not client.peer_exists("peer-abc"),
    )


def main(trace_path: Path | None = None) -> None:
    if trace_path is None:
        with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as handle:
            trace_path = Path(handle.name)
    run_poc3_demo(trace_path, quiet=False)


if __name__ == "__main__":
    main()
