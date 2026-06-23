"""Tests for NetBirdRevocationBackend."""

from capability_runtime.netbird_backend import NetBirdRevocationBackend
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding
from capability_runtime.types import CapabilityRef


def test_backend_revokes_route_then_peer():
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "peer": "peer-abc"}],
    )
    backend = NetBirdRevocationBackend(client)
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1",
    )
    backend.revoke_binding(binding, reason="policy")
    assert not client.route_exists("route-1")
    assert not client.peer_exists("peer-abc")
