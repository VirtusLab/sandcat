"""Tests for NetBirdRevocationBackend."""

from capability_runtime.netbird_backend import NetBirdRevocationBackend
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.types import CapabilityRef


def test_backend_disables_route_keeps_peer_by_default():
    """Default sync_mode (ROUTE_ENABLE) disables route, keeps peer."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    backend = NetBirdRevocationBackend(client)
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1",
        sync_mode=SyncMode.ROUTE_ENABLE,
    )
    backend.revoke_binding(binding, reason="policy")
    # Route should still exist but be disabled
    assert client.route_exists("route-1")
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert len(routes) == 1
    assert routes[0]["enabled"] is False
    # Peer should still exist
    assert client.peer_exists("peer-abc")


def test_backend_removes_peer_when_peer_remove_mode():
    """sync_mode=PEER_REMOVE deletes peer (Phase 3 compat)."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc", "enabled": True}],
    )
    backend = NetBirdRevocationBackend(client)
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1",
        sync_mode=SyncMode.PEER_REMOVE,
    )
    backend.revoke_binding(binding, reason="policy")
    # Peer should be deleted in PEER_REMOVE mode
    assert not client.peer_exists("peer-abc")
