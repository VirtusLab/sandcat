"""Test L7 revocation push integration in CapabilityRuntime (primary seam)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from lease_support import register_test_policy
from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, RevocationClosePolicy
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef

OPERATOR = AgentIdentity("operator")
AGENT = AgentIdentity("devcontainer-agent")
REF = CapabilityRef("cap-reach-api")


def _binding(**overrides) -> NetworkBinding:
    kwargs = {
        "capability_ref": REF,
        "peer_id": "peer-abc",
        "network": "10.8.0.0/24",
        "route_id": "route-1",
    }
    kwargs.update(overrides)
    return NetworkBinding(**kwargs)


def _runtime(tmp_path, socket_path, *, netbird_client=None) -> CapabilityRuntime:
    return CapabilityRuntime(
        trace_file=tmp_path / "trace.jsonl",
        trace_id="test-trace",
        seed=42,
        netbird_client=netbird_client,
        l7_revoke_socket=socket_path,
    )


def _events(runtime, name) -> list[dict]:
    return [e for e in runtime.observability._events if e.get("event") == name]


def test_logical_revoke_pushes_l7_with_catalog_policy(tmp_path, revoke_peer):
    peer = revoke_peer()
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = _runtime(tmp_path, peer.socket_path, netbird_client=client)
    runtime.register_network_capability(
        "reach_api",
        REF,
        _binding(
            revoke_close_policy=RevocationClosePolicy.DRAIN,
            revoke_drain_seconds=30,
        ),
        LifecycleState.VISIBLE,
    )

    runtime.revoke_capability(OPERATOR, REF, "stop")

    params = peer.wait()[0]["params"]
    assert params["host_patterns"] == ["10.8.0.0/24"]
    assert params["close_policy"] == "drain"
    assert params["drain_seconds"] == 30
    assert params["capability_ref"] == "cap-reach-api"
    assert params["reason"] == "stop"
    assert params["trigger"] == "operator"

    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False

    pushed = _events(runtime, "l7_revoke_push")
    assert len(pushed) == 1
    assert pushed[0]["close_policy"] == "drain"
    assert pushed[0]["host_patterns"] == ["10.8.0.0/24"]
    assert pushed[0]["final_drain_seconds"] == 30


def test_cli_immediate_overrides_catalog_drain(tmp_path, revoke_peer):
    peer = revoke_peer()
    runtime = _runtime(tmp_path, peer.socket_path, netbird_client=MockNetBirdClient())
    runtime.register_network_capability(
        "reach_api",
        REF,
        _binding(
            revoke_close_policy=RevocationClosePolicy.DRAIN,
            revoke_drain_seconds=60,
        ),
        LifecycleState.VISIBLE,
    )

    runtime.revoke_capability(
        OPERATOR, REF, "emergency", close_policy=RevocationClosePolicy.IMMEDIATE
    )

    params = peer.wait()[0]["params"]
    assert params["close_policy"] == "immediate"
    assert params["drain_seconds"] is None


def test_immediate_reports_the_drain_it_actually_pushed(tmp_path, revoke_peer):
    """The trace must not claim a 60s drain the proxy was never told about."""
    peer = revoke_peer()
    runtime = _runtime(tmp_path, peer.socket_path, netbird_client=MockNetBirdClient())
    runtime.register_network_capability(
        "reach_api",
        REF,
        _binding(
            revoke_close_policy=RevocationClosePolicy.DRAIN,
            revoke_drain_seconds=60,
        ),
        LifecycleState.VISIBLE,
    )

    runtime.revoke_capability(
        OPERATOR, REF, "emergency", close_policy=RevocationClosePolicy.IMMEDIATE
    )

    pushed = _events(runtime, "l7_revoke_push")[0]
    assert "final_drain_seconds" not in pushed
    assert pushed["close_policy"] == "immediate"


def test_push_failure_still_physically_revokes(tmp_path):
    """L7 push failure doesn't prevent physical revocation."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = _runtime(tmp_path, tmp_path / "missing.sock", netbird_client=client)
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)

    runtime.revoke_capability(OPERATOR, REF, "stop")

    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    assert len(_events(runtime, "l7_revoke_push_failed")) == 1

    revoked = _events(runtime, "capability_revoked")
    assert len(revoked) == 1
    assert revoked[0]["physical_revocation"] is True


def test_push_happens_without_a_netbird_backend(tmp_path, revoke_peer):
    """L7 revocation is additive: it does not depend on a NetBird backend."""
    peer = revoke_peer()
    runtime = _runtime(tmp_path, peer.socket_path)
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)

    runtime.revoke_capability(OPERATOR, REF, "stop")

    params = peer.wait()[0]["params"]
    assert params["host_patterns"] == ["10.8.0.0/24"]
    assert len(_events(runtime, "l7_revoke_push")) == 1
    assert _events(runtime, "capability_revoked")[0]["physical_revocation"] is False


def test_push_happens_even_when_physical_revoke_fails(tmp_path, revoke_peer):
    """A NetBird outage must not also cost us the proxy-side deny."""
    peer = revoke_peer()
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = _runtime(tmp_path, peer.socket_path, netbird_client=client)
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)

    def _boom(*args, **kwargs):
        raise RuntimeError("netbird unreachable")

    runtime._netbird_backend.revoke_binding = _boom

    with pytest.raises(RuntimeError, match="netbird unreachable"):
        runtime.revoke_capability(OPERATOR, REF, "stop")

    assert peer.wait()[0]["method"] == "mitmproxy.l7.revoke_flows"
    assert len(_events(runtime, "l7_revoke_push")) == 1


def test_ttl_expiry_pushes_l7_and_revokes_even_when_push_fails(tmp_path):
    """A failed push is not a physical sync failure and must not block revoke."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = _runtime(tmp_path, tmp_path / "missing.sock", netbird_client=client)
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)
    register_test_policy("reach_api")

    decision = runtime.request_capability_lease(AGENT, AGENT, REF, "need it")

    runtime.process_expired_network_leases(
        now=datetime.now(timezone.utc) + timedelta(hours=1)
    )

    assert _events(runtime, "physical_sync_failed") == []
    assert len(_events(runtime, "l7_revoke_push_failed")) == 1
    assert runtime.revocation_manager.is_lease_revoked(decision.lease_id) is True


def test_lease_grant_restores_previously_revoked_hosts(tmp_path, revoke_peer):
    """Re-granting after an expiry must clear the proxy's standing deny."""
    peer = revoke_peer(expected=3)
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = _runtime(tmp_path, peer.socket_path, netbird_client=client)
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)

    register_test_policy("reach_api")
    runtime.request_capability_lease(AGENT, AGENT, REF, "need it")
    runtime.process_expired_network_leases(
        now=datetime.now(timezone.utc) + timedelta(hours=1)
    )
    decision = runtime.request_capability_lease(AGENT, AGENT, REF, "need it again")

    requests = peer.wait()
    assert [r["method"] for r in requests] == [
        "mitmproxy.l7.restore_flows",  # first grant
        "mitmproxy.l7.revoke_flows",  # TTL expiry
        "mitmproxy.l7.restore_flows",  # re-grant
    ]
    restore = requests[2]["params"]
    assert restore["host_patterns"] == ["10.8.0.0/24"]
    assert restore["capability_ref"] == "cap-reach-api"
    assert restore["lease_id"] == decision.lease_id.value

    restored = _events(runtime, "l7_restore_push")
    assert len(restored) == 2
    assert restored[-1]["trigger"] == "lease_granted"


def test_lease_grant_restores_without_a_netbird_backend(tmp_path, revoke_peer):
    peer = revoke_peer()
    runtime = _runtime(tmp_path, peer.socket_path)
    runtime.register_network_capability(
        "reach_api",
        REF,
        _binding(dns_label="peer-proxy.netbird.selfhosted"),
        LifecycleState.VISIBLE,
    )

    register_test_policy("reach_api")
    runtime.request_capability_lease(AGENT, AGENT, REF, "need it")

    params = peer.wait()[0]["params"]
    assert params["host_patterns"] == ["10.8.0.0/24", "peer-proxy.netbird.selfhosted"]


def test_lease_grant_survives_restore_push_failure(tmp_path):
    """The proxy being down must not fail the grant itself."""
    runtime = _runtime(tmp_path, tmp_path / "missing.sock")
    runtime.register_network_capability("reach_api", REF, _binding(), LifecycleState.VISIBLE)
    register_test_policy("reach_api")

    decision = runtime.request_capability_lease(AGENT, AGENT, REF, "need it")

    assert decision.lease_id is not None
    assert len(_events(runtime, "l7_restore_push_failed")) == 1


def test_tool_lease_does_not_push_restore(tmp_path):
    register_test_policy("create_pr")
    runtime = _runtime(tmp_path, tmp_path / "missing.sock")

    runtime.request_capability_lease(
        AGENT, AGENT, CapabilityRef("cap-create-pr"), "need a PR"
    )

    assert _events(runtime, "l7_restore_push_failed") == []
    assert _events(runtime, "l7_restore_push") == []
