from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.catalog import LifecycleState
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity
from capability_runtime.types import CapabilityRef
import json


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
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED


def test_watcher_revokes_when_route_disabled_with_active_lease(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.route_watcher import RouteDisappearanceWatcher
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rw-lease", 5, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    runtime.request_capability_lease(agent, agent, ref, "need api")

    client._routes[0]["enabled"] = False

    RouteDisappearanceWatcher(runtime, client).poll_once()

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED


def test_watcher_reconciles_route_after_failed_physical_revoke(tmp_path, monkeypatch):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.route_watcher import RouteDisappearanceWatcher
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rw-reconcile", 6, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    runtime.request_capability_lease(agent, agent, ref, "need api")

    fail_once = [True]
    original_disable = client.disable_binding

    def flaky_disable(binding):
        if fail_once[0]:
            fail_once[0] = False
            raise RuntimeError("netbird down")
        return original_disable(binding)

    monkeypatch.setattr(client, "disable_binding", flaky_disable)
    runtime.revoke_capability(AgentIdentity("operator"), ref, "security")
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is True

    RouteDisappearanceWatcher(runtime, client).poll_once()

    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]


def test_watcher_ignores_declared_binding_when_route_disabled(tmp_path):
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


def test_watcher_emits_event_when_reconcile_disable_fails(tmp_path, monkeypatch):
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc"}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-rw-fail", 7, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    runtime.request_capability_lease(agent, agent, ref, "need api")
    runtime.revoke_capability(AgentIdentity("operator"), ref, "operator revoke")
    client._routes[0]["enabled"] = True

    def always_fail(_binding):
        raise RuntimeError("netbird still down")

    monkeypatch.setattr(client, "disable_binding", always_fail)

    RouteDisappearanceWatcher(runtime, client).poll_once()

    events = [json.loads(line) for line in (tmp_path / "t.jsonl").read_text().splitlines() if line]
    reconcile_failures = [e for e in events if e.get("event") == "physical_reconcile_failed"]
    assert reconcile_failures
    assert reconcile_failures[-1]["capability_ref"] == "cap-reach-api"
    assert reconcile_failures[-1]["route_id"] == "route-1"
