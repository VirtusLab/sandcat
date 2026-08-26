# capability-runtime/tests/test_re_lease_after_revoke.py
from datetime import datetime, timedelta, timezone

from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef

_OPERATOR = AgentIdentity("operator")


def test_re_lease_after_revoke_by_ref(tmp_path):
    """Operator revoke followed by another lease should succeed without sidecar restart."""
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-re", 2, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None, sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    runtime.request_capability_lease(agent, agent, ref, "first lease")
    runtime.revoke_capability(_OPERATOR, ref, "done")
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED

    decision2 = runtime.request_capability_lease(agent, agent, ref, "second lease")
    assert decision2.lease_id is not None
    assert runtime.catalog.get_state(ref) == LifecycleState.LEASED

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]

    # Route is re-enabled after re-grant
    assert len(client.list_routes()) >= 1


def test_re_lease_after_expiry(tmp_path):
    """Re-lease after TTL expiry continues to work."""
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-exp", 3, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None, sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    decision1 = runtime.request_capability_lease(agent, agent, ref, "first lease")
    runtime.lease_manager._leases[decision1.lease_id].expires_at = (
        datetime.now(timezone.utc) - timedelta(seconds=1)
    )
    runtime.check_current_capabilities(agent, {})
    assert runtime.catalog.get_state(ref) == LifecycleState.EXPIRED

    decision2 = runtime.request_capability_lease(agent, agent, ref, "second lease")
    assert decision2.lease_id is not None
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]
    assert bundle.networks[0].lease_id == decision2.lease_id


def test_re_lease_after_physical_revoke(tmp_path):
    """re-lease succeeds after RouteDisappearanceWatcher triggers logical revoke."""
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-phys", 2, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None, sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    runtime.request_capability_lease(agent, agent, ref, "first lease")

    # Simulate external peer removal triggering logical revoke (no NetBird API call)
    runtime.revoke_from_physical(binding, "peer disappeared")
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED

    # Re-lease should succeed; peer still in mock
    decision2 = runtime.request_capability_lease(agent, agent, ref, "second lease")
    assert decision2.lease_id is not None
    assert runtime.catalog.get_state(ref) == LifecycleState.LEASED

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]


def test_re_lease_with_dns_label_resolves_new_peer(tmp_path):
    """After proxy-peer replace, re-lease resolves the new peer_id and persists it."""
    peer_a = {
        "id": "peer-old-id",
        "ip": "100.64.0.5",
        "dns_label": "cv-sandbox-proxy-peer.netbird.selfhosted",
        "connected": True,
    }
    peer_b = {
        "id": "peer-new-id",
        "ip": "100.64.0.7",
        "dns_label": "cv-sandbox-proxy-peer.netbird.selfhosted",
        "connected": True,
    }
    client = MockNetBirdClient(peers=[peer_a], routes=[])
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl", "trace-dns-swap", 2, netbird_client=client
    )
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-proxy")
    binding = NetworkBinding(
        ref,
        peer_id="peer-placeholder",
        network="0.0.0.0/32",
        route_id=None,
        dns_label="cv-sandbox-proxy-peer.netbird.selfhosted",
    )
    runtime.register_network_capability("reach_proxy", ref, binding, LifecycleState.VISIBLE)

    # First lease: resolves peer A
    runtime.request_capability_lease(agent, agent, ref, "first lease")
    after_first = runtime.catalog.get_network_binding(ref)
    assert after_first.peer_id == "peer-old-id"

    # Physical revoke (old peer gone after container replace)
    runtime.revoke_from_physical(after_first, "peer disappeared")
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED

    # Swap mock peers: new enrollment, same dns_label, new peer_id and IP
    client._peers = [peer_b]

    # Re-lease: dns_label resolution picks up peer B
    decision2 = runtime.request_capability_lease(agent, agent, ref, "second lease")
    assert decision2.lease_id is not None

    after_second = runtime.catalog.get_network_binding(ref)
    assert after_second.peer_id == "peer-new-id", "binding must be updated to new peer"
    assert after_second.network == "100.64.0.7/32", "network must reflect new mesh IP"

    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_proxy" in [n.name for n in bundle.networks]


def test_re_lease_after_quota_exhaustion_leaves_expired_state(tmp_path):
    """Quota exhaustion ends as EXPIRED (re-leasable), not REVOKED."""
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-quota", 1, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None, sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    decision1 = runtime.request_capability_lease(agent, agent, ref, "first lease")
    now = datetime.now(timezone.utc)
    runtime.record_action(agent, agent, decision1.lease_id, now)
    assert runtime.catalog.get_state(ref) == LifecycleState.EXPIRED

    # Should be re-leasable from EXPIRED (not REVOKED, which would also work after task 1)
    decision2 = runtime.request_capability_lease(agent, agent, ref, "re-grant after quota")
    assert decision2.lease_id is not None
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]
