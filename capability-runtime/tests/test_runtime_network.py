from lease_support import register_test_policy


def test_register_network_capability_appears_in_bundle_when_visible(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    operator = AgentIdentity("operator")

    client = MockNetBirdClient()
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n1", 1, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    bundle = runtime.check_current_capabilities(agent, {})
    assert any(n.name == "reach_api" for n in bundle.networks)
    cap = next(n for n in bundle.networks if n.name == "reach_api")
    assert cap.peer_id == "peer-abc"


def test_revoke_network_capability_calls_netbird_backend(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    operator = AgentIdentity("operator")

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n2", 2, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    runtime.revoke_capability(operator, ref, "security")
    # Default sync_mode (ROUTE_ENABLE) keeps peer, disables route
    assert client.peer_exists("peer-abc")
    assert client.route_exists("route-1")
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    # Capability should be logically revoked
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]


def test_revoke_by_ref_fails_closed_when_netbird_disable_fails(tmp_path, monkeypatch):

    import pytest

    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, SyncMode
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    operator = AgentIdentity("operator")
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n2-fail", 8, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    register_test_policy("reach_api")
    runtime.request_capability_lease(agent, agent, ref, "need api")

    def boom(*_a, **_kw):
        raise RuntimeError("netbird down")

    monkeypatch.setattr(client, "disable_binding", boom)
    with pytest.raises(RuntimeError, match="netbird down"):
        runtime.revoke_capability(operator, ref, "security")

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]
    assert runtime.catalog.get_state(ref) == LifecycleState.LEASED
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is True


def test_revoke_non_network_capability_does_not_call_netbird(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    operator = AgentIdentity("operator")

    client = MockNetBirdClient(
        peers=[{"id": "peer-xyz", "connected": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n3", 3, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-create-pr")
    runtime.catalog.register("create_pr_tool", ref, LifecycleState.VISIBLE)
    runtime.revoke_capability(operator, ref, "security")
    # Peer should still exist because we didn't revoke a network capability
    assert client.peer_exists("peer-xyz")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "create_pr_tool" not in [t.name for t in bundle.tools]


def test_quota_exhaustion_disables_network_binding(tmp_path):
    """When quota is exhausted for a network lease, disable the binding."""
    from datetime import datetime, timezone
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-quota", "connected": True}],
        routes=[{"id": "route-quota", "network": "192.168.1.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-quota", 1, netbird_client=client)
    agent = AgentIdentity("agent-quota")
    ref = CapabilityRef("cap-quota-test")
    binding = NetworkBinding(ref, "peer-quota", "192.168.1.0/24", "route-quota")
    runtime.register_network_capability("quota_net", ref, binding, LifecycleState.DECLARED)
    register_test_policy("quota_net")
    
    # Lease with quota=1
    decision = runtime.request_capability_lease(agent, agent, ref, "testing quota")
    
    # Exhaust quota
    now = datetime.now(timezone.utc)
    runtime.record_action(agent, agent, decision.lease_id, now)
    
    # Peer should still exist, route should be disabled
    assert client.peer_exists("peer-quota")
    assert client.route_exists("route-quota")
    routes = [r for r in client.list_routes() if r["id"] == "route-quota"]
    assert routes[0]["enabled"] is False


def test_ttl_expiry_disables_network_binding(tmp_path):
    """When a lease expires (TTL), disable the binding on next bundle check."""
    from datetime import datetime, timedelta, timezone
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-ttl", "connected": True}],
        routes=[{"id": "route-ttl", "network": "172.16.0.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-ttl", 2, netbird_client=client)
    agent = AgentIdentity("agent-ttl")
    ref = CapabilityRef("cap-ttl-test")
    binding = NetworkBinding(ref, "peer-ttl", "172.16.0.0/24", "route-ttl")
    runtime.register_network_capability("ttl_net", ref, binding, LifecycleState.DECLARED)
    register_test_policy("ttl_net")

    decision = runtime.request_capability_lease(agent, agent, ref, "testing ttl")
    runtime.lease_manager._leases[decision.lease_id].expires_at = (
        datetime.now(timezone.utc) - timedelta(seconds=1)
    )

    bundle = runtime.check_current_capabilities(agent, {})

    assert client.peer_exists("peer-ttl")
    routes = [r for r in client.list_routes() if r["id"] == "route-ttl"]
    assert routes[0]["enabled"] is False
    assert "ttl_net" not in [n.name for n in bundle.networks]


def test_ttl_expiry_via_watcher_poll(tmp_path):
    """Watcher poll processes TTL expiry without requiring capability.check."""
    from datetime import datetime, timedelta, timezone
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, SyncMode
    from capability_runtime.route_watcher import RouteDisappearanceWatcher
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-ttl", "connected": True}],
        routes=[{"id": "route-ttl", "network": "172.16.0.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-ttl-w", 3, netbird_client=client)
    agent = AgentIdentity("agent-ttl")
    ref = CapabilityRef("cap-ttl-watcher")
    binding = NetworkBinding(ref, "peer-ttl", "172.16.0.0/24", "route-ttl", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("ttl_net", ref, binding, LifecycleState.VISIBLE)
    register_test_policy("ttl_net")
    decision = runtime.request_capability_lease(agent, agent, ref, "testing ttl")
    runtime.lease_manager._leases[decision.lease_id].expires_at = (
        datetime.now(timezone.utc) - timedelta(seconds=1)
    )

    RouteDisappearanceWatcher(runtime, client).poll_once()

    routes = [r for r in client.list_routes() if r["id"] == "route-ttl"]
    assert routes[0]["enabled"] is False
    assert runtime.catalog.get_state(ref) == LifecycleState.EXPIRED


def test_ttl_expiry_fails_closed_when_netbird_disable_fails(tmp_path, monkeypatch):
    from datetime import datetime, timedelta, timezone
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, SyncMode
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[{"id": "route-1", "enabled": True}])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-ttl", 4, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    register_test_policy("reach_api")
    decision = runtime.request_capability_lease(agent, agent, ref, "ttl test")

    runtime.lease_manager._leases[decision.lease_id].expires_at = (
        datetime.now(timezone.utc) - timedelta(seconds=1)
    )

    def boom(*_a, **_kw):
        raise RuntimeError("netbird down")

    monkeypatch.setattr(client, "disable_binding", boom)

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]
    assert runtime.catalog.get_state(ref) == LifecycleState.LEASED
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is True
