"""Integration tests for PoC 3 network route lifecycle (spec Phase 3)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from lease_support import register_test_policy
from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef, LeaseDecision


@dataclass
class _Poc3Result:
    initial_networks: list[str]
    lease_decision: LeaseDecision
    networks_after_lease: list[str]
    peer_id_after_lease: str | None
    peer_still_exists_after_revoke: bool
    route_disabled_by_revoke: bool
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


def _run_reach_api_lifecycle(trace_path: Path) -> _Poc3Result:
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24"}],
    )
    runtime = CapabilityRuntime(
        trace_path, "poc3-network-route", seed=42, netbird_client=client
    )
    watcher = RouteDisappearanceWatcher(runtime, client)
    agent = AgentIdentity("demo-agent")
    context: dict = {}
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")

    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)
    register_test_policy("reach_api")

    bundle1 = runtime.check_current_capabilities(agent, context)
    initial_networks = _network_names(bundle1)

    decision = runtime.request_capability_lease(
        agent,
        agent,
        ref,
        "Need API reachability for integration test",
    )

    bundle2 = runtime.check_current_capabilities(agent, context)
    networks_after_lease = _network_names(bundle2)
    peer_id = _peer_id_for(bundle2, "reach_api")

    runtime.revoke_capability(AgentIdentity("operator"), ref, "security policy")
    peer_still_exists = client.peer_exists("peer-abc")
    route_disabled = False
    if client.route_exists("route-1"):
        routes = [r for r in client.list_routes() if r["id"] == "route-1"]
        route_disabled = routes[0]["enabled"] is False if routes else False

    bundle3 = runtime.check_current_capabilities(agent, context)
    networks_after_revoke = _network_names(bundle3)

    client._peers.append({"id": "peer-abc", "connected": True})
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    client.remove_peer("peer-abc")
    watcher.poll_once()
    bundle4 = runtime.check_current_capabilities(agent, context)
    networks_after_external = _network_names(bundle4)

    return _Poc3Result(
        initial_networks=initial_networks,
        lease_decision=decision,
        networks_after_lease=networks_after_lease,
        peer_id_after_lease=peer_id,
        peer_still_exists_after_revoke=peer_still_exists,
        route_disabled_by_revoke=route_disabled,
        networks_after_revoke=networks_after_revoke,
        networks_after_external_removal=networks_after_external,
        external_removal_peer_gone=not client.peer_exists("peer-abc"),
    )


def test_poc3_network_route_lifecycle(tmp_path: Path) -> None:
    """reach_api absent → lease → present → revoke → absent → external removal stays absent."""
    result = _run_reach_api_lifecycle(tmp_path / "trace.jsonl")

    assert "reach_api" not in result.initial_networks
    assert result.lease_decision.capability_ref == CapabilityRef("cap-reach-api")
    assert "reach_api" in result.networks_after_lease
    assert result.peer_id_after_lease == "peer-abc"
    # Phase 3c: prefer disable over peer delete
    assert result.peer_still_exists_after_revoke is True
    assert result.route_disabled_by_revoke is True
    assert "reach_api" not in result.networks_after_revoke
    assert "reach_api" not in result.networks_after_external_removal
    assert result.external_removal_peer_gone is True
