from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.types import CapabilityRef


def test_get_route_state_enabled():
    client = MockNetBirdClient(
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    binding = NetworkBinding(CapabilityRef("cap-reach-api"), "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    assert client.get_route_state(binding) == "enabled"


def test_get_route_state_disabled():
    client = MockNetBirdClient(
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": False}],
    )
    binding = NetworkBinding(CapabilityRef("cap-reach-api"), "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    assert client.get_route_state(binding) == "disabled"


def test_get_route_state_missing():
    client = MockNetBirdClient(routes=[])
    binding = NetworkBinding(CapabilityRef("cap-reach-api"), "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    assert client.get_route_state(binding) == "missing"


def test_watcher_revokes_when_route_disabled_but_peer_exists(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.route_watcher import RouteDisappearanceWatcher
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rw", 3, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    client._routes[0]["enabled"] = False

    RouteDisappearanceWatcher(runtime, client).poll_once()

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]


def test_watcher_ignores_declared_binding_when_route_disabled(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.route_watcher import RouteDisappearanceWatcher
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": False}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rw2", 4, netbird_client=client)
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)

    RouteDisappearanceWatcher(runtime, client).poll_once()

    assert runtime.catalog.get_state(ref) == LifecycleState.DECLARED
