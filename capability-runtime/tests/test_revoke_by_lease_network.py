# capability-runtime/tests/test_revoke_by_lease_network.py
"""Revoke by lease ID must disable network bindings."""

from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef

_OPERATOR = AgentIdentity("operator")


def test_revoke_by_lease_id_disables_network_route(tmp_path):
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rl", 1, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    decision = runtime.request_capability_lease(agent, agent, ref, "need api")
    version_before = runtime._bundle_version
    runtime.revoke_capability(_OPERATOR, decision.lease_id, "operator revoke")

    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    assert client.peer_exists("peer-abc")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]
    assert runtime._bundle_version > version_before


def test_revoke_by_lease_id_skips_netbird_for_tool_capability(tmp_path):
    """Tool leases must not call NetBird on revoke-by-lease-ID."""
    client = MockNetBirdClient(peers=[{"id": "peer-xyz"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rl-tool", 2, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-create-pr")
    runtime.catalog.register("create_pr", ref, LifecycleState.VISIBLE)

    decision = runtime.request_capability_lease(agent, agent, ref, "need pr")
    runtime.revoke_capability(_OPERATOR, decision.lease_id, "done")

    assert client.list_routes() == []
    assert client.peer_exists("peer-xyz")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "create_pr" not in [t.name for t in bundle.tools]
