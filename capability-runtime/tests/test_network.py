from capability_runtime.network import (
    NetworkBinding,
    PhysicalRevocationBackend,
    SyncMode,
    sync_mode_from_catalog,
)
from capability_runtime.types import CapabilityRef, NetworkCapability


def test_network_capability_in_bundle():
    cap = NetworkCapability(
        ref=CapabilityRef("cap-reach-api"),
        name="reach_api",
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1",
        lease_id=None,
    )
    assert cap.peer_id == "peer-abc"
    assert cap.network == "10.8.0.0/24"


def test_network_binding_dataclass():
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1",
    )
    assert binding.route_id == "route-1"


def test_network_binding_default_sync_mode():
    binding = NetworkBinding(
        CapabilityRef("cap-reach-api"),
        "peer-abc",
        "10.8.0.0/24",
        "route-1",
    )
    assert binding.sync_mode is SyncMode.ROUTE_ENABLE


def test_network_binding_explicit_sync_mode():
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id=None,
        sync_mode=SyncMode.ACL_POLICY,
    )
    assert binding.sync_mode is SyncMode.ACL_POLICY


def test_sync_mode_from_catalog_flat_entry():
    entry = {
        "peer_id": "peer-abc",
        "network": "10.8.0.0/24",
        "route_id": None,
        "sync_mode": "acl_policy",
    }
    assert sync_mode_from_catalog(entry) is SyncMode.ACL_POLICY


def test_sync_mode_from_catalog_nested_binding():
    entry = {
        "ref": "cap-reach-api",
        "name": "reach_api",
        "binding": {
            "peer_id": "peer-abc",
            "network": "10.8.0.0/24",
            "route_id": None,
            "sync_mode": "route_enable",
        },
    }
    assert sync_mode_from_catalog(entry) is SyncMode.ROUTE_ENABLE


def test_sync_mode_from_catalog_defaults_to_route_enable():
    assert sync_mode_from_catalog({"peer_id": "peer-abc"}) is SyncMode.ROUTE_ENABLE
    assert (
        sync_mode_from_catalog({"binding": {"peer_id": "peer-abc"}})
        is SyncMode.ROUTE_ENABLE
    )


def test_sync_mode_from_catalog_peer_remove():
    entry = {"sync_mode": "peer_remove"}
    assert sync_mode_from_catalog(entry) is SyncMode.PEER_REMOVE


class _StubBackend:
    def revoke_peer(self, peer_id: str, reason: str) -> None:
        pass

    def revoke_route(self, route_id: str, reason: str) -> None:
        pass

    def grant_binding(self, binding: NetworkBinding) -> None:
        pass

    def revoke_binding(self, binding: NetworkBinding, reason: str) -> None:
        pass


def test_physical_revocation_backend_protocol_includes_grant_and_revoke_binding():
    backend: PhysicalRevocationBackend = _StubBackend()
    binding = NetworkBinding(
        CapabilityRef("cap-reach-api"),
        "peer-abc",
        "10.8.0.0/24",
        None,
    )
    backend.grant_binding(binding)
    backend.revoke_binding(binding, reason="test")
