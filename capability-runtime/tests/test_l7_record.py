"""Tests for L7 flow recording and admin capability.l7.record RPC."""

from __future__ import annotations

from datetime import timedelta

from capability_runtime.catalog import LifecycleState
from capability_runtime.l7_record import record_l7_flow
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.policy import LeasePolicy, register_lease_policy
from capability_runtime.rpc.dispatcher import RpcDispatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_l7_record_decrements_network_lease_quota(tmp_path):
    client = MockNetBirdClient(peers=[{"id": "peer-pp"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace", 1, netbird_client=client)
    agent = AgentIdentity("devcontainer-agent")
    ref = CapabilityRef("cap-reach-proxy")
    binding = NetworkBinding(ref, "peer-pp", "100.64.0.5/32", None, SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_proxy", ref, binding, LifecycleState.VISIBLE)
    register_lease_policy(
        "reach_proxy",
        LeasePolicy(
            quota=2,
            ttl=timedelta(minutes=15),
            token_budget=10000,
            risk_envelope="medium",
        ),
    )
    decision = runtime.request_capability_lease(agent, agent, ref, "test")
    record_l7_flow(runtime, agent, host="100.64.0.5", method="GET", status=200)
    record_l7_flow(runtime, agent, host="100.64.0.5", method="GET", status=200)
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_proxy" not in [n.name for n in bundle.networks]
    assert decision.lease_id is not None


def test_agent_surface_rejects_l7_record(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-l7", 500)
    dispatcher = RpcDispatcher(
        runtime, surface="agent", bound_agent_id="devcontainer-agent"
    )
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.l7.record",
            "params": {
                "host": "100.64.0.5",
                "method": "GET",
                "status": 200,
            },
        }
    )
    assert "error" in response
    assert response["error"]["code"] == -32601


def test_admin_surface_records_l7_flow(tmp_path):
    client = MockNetBirdClient(peers=[{"id": "peer-pp"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace", 1, netbird_client=client)
    agent = AgentIdentity("devcontainer-agent")
    ref = CapabilityRef("cap-reach-proxy")
    binding = NetworkBinding(ref, "peer-pp", "100.64.0.5/32", None, SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_proxy", ref, binding, LifecycleState.VISIBLE)
    register_lease_policy(
        "reach_proxy",
        LeasePolicy(
            quota=2,
            ttl=timedelta(minutes=15),
            token_budget=10000,
            risk_envelope="medium",
        ),
    )
    runtime.request_capability_lease(agent, agent, ref, "test")

    dispatcher = RpcDispatcher(runtime, surface="admin", bound_agent_id="operator")
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.l7.record",
            "params": {
                "agent_id": "devcontainer-agent",
                "host": "100.64.0.5",
                "method": "GET",
                "status": 200,
                "trace_id": "trace-abc",
            },
        }
    )
    assert "result" in response
    assert response["result"]["recorded"] is True
