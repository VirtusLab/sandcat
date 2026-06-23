from capability_runtime.network import NetworkBinding, PhysicalRevocationBackend
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
