"""Tests for dns_label resolution in NetworkBinding at lease time."""
from __future__ import annotations


def test_lease_with_dns_label_resolves_peer_id_and_enables_route(tmp_path):
    """Lease with dns_label resolves peer_id + mesh IP via peers API, enables /32 route."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[
            {
                "id": "peer-actual-id",
                "ip": "100.64.0.5",
                "dns_label": "peer-proxy.netbird.selfhosted",
                "connected": True,
            }
        ],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-dns-1", 1, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-proxy")
    # Catalog stores stable dns_label; peer_id/network are placeholders
    binding = NetworkBinding(
        ref,
        peer_id="peer-placeholder",
        network="0.0.0.0/32",
        route_id=None,
        dns_label="peer-proxy.netbird.selfhosted",
    )
    runtime.register_network_capability(
        "reach_proxy", ref, binding, LifecycleState.DECLARED
    )

    runtime.request_capability_lease(agent, agent, ref, "test dns resolution")

    routes = client.list_routes()
    assert len(routes) == 1, "Expected one route to be created"
    assert routes[0]["peer"] == "peer-actual-id", "Route must use resolved peer_id"
    assert routes[0]["network"] == "100.64.0.5/32", "Route must use resolved mesh IP /32"
    assert routes[0]["enabled"] is True


def test_lease_without_dns_label_uses_catalog_peer_id_directly(tmp_path):
    """IP-only binding (no dns_label) creates route with catalog peer_id unchanged."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-direct", "connected": True}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-dns-2", 2, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-direct", "10.8.0.0/24", route_id=None)
    runtime.register_network_capability(
        "reach_api", ref, binding, LifecycleState.DECLARED
    )

    runtime.request_capability_lease(agent, agent, ref, "direct ip")

    routes = client.list_routes()
    assert len(routes) == 1
    assert routes[0]["peer"] == "peer-direct"
    assert routes[0]["network"] == "10.8.0.0/24"


def test_lease_with_dns_label_not_found_raises(tmp_path):
    """Lease with dns_label that matches no peer raises PeerResolutionError."""
    import pytest

    from capability_runtime.catalog import LifecycleState
    from capability_runtime.errors import PeerResolutionError
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(peers=[], routes=[])
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-dns-3", 3, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-proxy")
    binding = NetworkBinding(
        ref,
        peer_id="peer-placeholder",
        network="0.0.0.0/32",
        route_id=None,
        dns_label="missing.netbird.selfhosted",
    )
    runtime.register_network_capability(
        "reach_proxy", ref, binding, LifecycleState.DECLARED
    )

    with pytest.raises(PeerResolutionError, match="missing.netbird.selfhosted"):
        runtime.request_capability_lease(agent, agent, ref, "test missing peer")


def test_find_peer_by_dns_label_exact_match():
    """find_peer_by_dns_label returns peer dict on exact dns_label match."""
    from capability_runtime.netbird_client import MockNetBirdClient

    client = MockNetBirdClient(
        peers=[
            {"id": "p1", "dns_label": "peer-proxy.netbird.selfhosted", "ip": "100.64.0.5"},
            {"id": "p2", "dns_label": "other.netbird.selfhosted", "ip": "100.64.0.6"},
        ]
    )
    peer = client.find_peer_by_dns_label("peer-proxy.netbird.selfhosted")
    assert peer is not None
    assert peer["id"] == "p1"


def test_find_peer_by_dns_label_prefix_match():
    """find_peer_by_dns_label matches when label equals hostname prefix of FQDN."""
    from capability_runtime.netbird_client import MockNetBirdClient

    client = MockNetBirdClient(
        peers=[
            {"id": "p1", "dns_label": "peer-proxy.netbird.selfhosted", "ip": "100.64.0.5"},
        ]
    )
    # Short name matches if FQDN starts with "<short>."
    peer = client.find_peer_by_dns_label("peer-proxy")
    assert peer is not None
    assert peer["id"] == "p1"


def test_find_peer_by_dns_label_returns_none_when_missing():
    """find_peer_by_dns_label returns None when no peer matches."""
    from capability_runtime.netbird_client import MockNetBirdClient

    client = MockNetBirdClient(peers=[{"id": "p1", "dns_label": "other", "ip": "1.2.3.4"}])
    assert client.find_peer_by_dns_label("not-there") is None


def test_dns_label_resolution_clears_stale_route_id(tmp_path):
    """After proxy-peer recreation, stale route_id is discarded and a new route is created for the new peer."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    # Simulate proxy-peer recreation: new peer ID and new mesh IP
    client = MockNetBirdClient(
        peers=[
            {
                "id": "peer-new-id",
                "ip": "100.64.0.99",
                "dns_label": "peer-proxy.netbird.selfhosted",
                "connected": True,
            }
        ],
        # An orphan route from the old peer enrollment still exists
        routes=[
            {
                "id": "old-route-1",
                "network": "100.64.0.5/32",
                "peer": "peer-old-id",
                "enabled": False,
            }
        ],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-stale", 5, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-proxy")
    # Catalog still has the old route_id cached from before recreation
    binding = NetworkBinding(
        ref,
        peer_id="peer-old-id",
        network="100.64.0.5/32",
        route_id="old-route-1",
        dns_label="peer-proxy.netbird.selfhosted",
    )
    runtime.register_network_capability(
        "reach_proxy", ref, binding, LifecycleState.DECLARED
    )

    runtime.request_capability_lease(agent, agent, ref, "test stale route")

    routes = client.list_routes()
    # Old route must NOT have been re-enabled
    old = next((r for r in routes if r["id"] == "old-route-1"), None)
    assert old is None or old.get("enabled") is False, (
        "Stale route for deleted peer must not be enabled"
    )
    # A new route targeting the resolved peer/IP must exist
    new_routes = [r for r in routes if r.get("peer") == "peer-new-id"]
    assert len(new_routes) == 1, "Expected one new route for the recreated peer"
    assert new_routes[0]["network"] == "100.64.0.99/32"
    assert new_routes[0]["enabled"] is True


def test_load_catalog_dns_label_sets_binding_field(tmp_path):
    """load_catalog_into_runtime stores dns_label on NetworkBinding."""
    import json

    from capability_runtime.daemon import load_catalog_into_runtime
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import CapabilityRef

    catalog = {
        "capabilities": [
            {
                "name": "reach_proxy",
                "ref": "cap-reach-proxy",
                "type": "network",
                "dns_label": "peer-proxy.netbird.selfhosted",
                "peer_id": "peer-placeholder",
                "network": "0.0.0.0/32",
                "sync_mode": "route_enable",
            }
        ]
    }
    catalog_path = tmp_path / "capability-catalog.json"
    catalog_path.write_text(json.dumps(catalog))

    client = MockNetBirdClient()
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-dns-4", 4, netbird_client=client
    )
    load_catalog_into_runtime(runtime, catalog_path)

    ref = CapabilityRef("cap-reach-proxy")
    binding = runtime.catalog.get_network_binding(ref)
    assert binding is not None
    assert binding.dns_label == "peer-proxy.netbird.selfhosted"


# ---------------------------------------------------------------------------
# peer_hostname resolution — router-peer CIDRs (e.g. reach_api).
# ---------------------------------------------------------------------------


def test_lease_with_peer_hostname_resolves_peer_id_keeps_network(tmp_path):
    """Lease with peer_hostname resolves peer_id from peer name; network stays unchanged."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[
            {
                "id": "mitmproxy-peer-id",
                "name": "sandcat-proxy",
                "ip": "100.64.0.1",
                "connected": True,
            }
        ],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-hostname-1", 10, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        ref,
        peer_id="",
        network="10.8.0.0/24",
        route_id=None,
        peer_hostname="sandcat-proxy",
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)

    runtime.request_capability_lease(agent, agent, ref, "test hostname resolution")

    routes = client.list_routes()
    assert len(routes) == 1
    assert routes[0]["peer"] == "mitmproxy-peer-id", "Route must use resolved peer_id"
    assert routes[0]["network"] == "10.8.0.0/24", "Network CIDR must be preserved (not rewritten to /32)"
    assert routes[0]["enabled"] is True


def test_peer_hostname_resolution_case_insensitive(tmp_path):
    """peer_hostname match is case-insensitive."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "pid", "name": "Sandcat-Proxy", "ip": "100.64.0.1"}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-hostname-2", 11, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        ref, peer_id="", network="10.8.0.0/24", route_id=None,
        peer_hostname="sandcat-proxy",
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)
    runtime.request_capability_lease(agent, agent, ref, "case insensitive")

    routes = client.list_routes()
    assert routes[0]["peer"] == "pid"


def test_peer_hostname_resolution_via_hostname_field(tmp_path):
    """peer_hostname matches peer['hostname'] when peer['name'] is absent."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "pid2", "hostname": "sandcat-proxy", "ip": "100.64.0.1"}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-hostname-3", 12, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        ref, peer_id="", network="10.8.0.0/24", route_id=None,
        peer_hostname="sandcat-proxy",
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)
    runtime.request_capability_lease(agent, agent, ref, "hostname field")

    routes = client.list_routes()
    assert routes[0]["peer"] == "pid2"


def test_peer_hostname_not_found_raises(tmp_path):
    """Lease with peer_hostname that matches no peer raises PeerResolutionError."""
    import pytest

    from capability_runtime.catalog import LifecycleState
    from capability_runtime.errors import PeerResolutionError
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(peers=[], routes=[])
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-hostname-4", 13, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        ref, peer_id="", network="10.8.0.0/24", route_id=None,
        peer_hostname="sandcat-proxy",
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.DECLARED)

    with pytest.raises(PeerResolutionError, match="sandcat-proxy"):
        runtime.request_capability_lease(agent, agent, ref, "test missing hostname")


def test_load_catalog_peer_hostname_sets_binding_field(tmp_path):
    """load_catalog_into_runtime stores peer_hostname on NetworkBinding."""
    import json

    from capability_runtime.daemon import load_catalog_into_runtime
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import CapabilityRef

    catalog = {
        "capabilities": [
            {
                "name": "reach_api",
                "ref": "cap-reach-api",
                "type": "network",
                "peer_id": "",
                "peer_hostname": "sandcat-proxy",
                "network": "10.8.0.0/24",
                "sync_mode": "route_enable",
            }
        ]
    }
    catalog_path = tmp_path / "capability-catalog.json"
    catalog_path.write_text(json.dumps(catalog))

    client = MockNetBirdClient()
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-hostname-5", 14, netbird_client=client
    )
    load_catalog_into_runtime(runtime, catalog_path)

    ref = CapabilityRef("cap-reach-api")
    binding = runtime.catalog.get_network_binding(ref)
    assert binding is not None
    assert binding.peer_hostname == "sandcat-proxy"
    assert binding.peer_id == ""


def test_find_peer_by_hostname_returns_peer():
    """find_peer_by_hostname returns the matching peer dict."""
    from capability_runtime.netbird_client import MockNetBirdClient

    client = MockNetBirdClient(
        peers=[
            {"id": "p1", "name": "sandcat-proxy", "ip": "100.64.0.1"},
            {"id": "p2", "name": "other-peer", "ip": "100.64.0.2"},
        ]
    )
    peer = client.find_peer_by_hostname("sandcat-proxy")
    assert peer is not None
    assert peer["id"] == "p1"


def test_find_peer_by_hostname_returns_none_when_missing():
    """find_peer_by_hostname returns None when no peer matches."""
    from capability_runtime.netbird_client import MockNetBirdClient

    client = MockNetBirdClient(peers=[{"id": "p1", "name": "other", "ip": "1.2.3.4"}])
    assert client.find_peer_by_hostname("sandcat-proxy") is None
