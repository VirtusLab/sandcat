"""Tests for JSON-RPC dispatcher with agent/admin surface allowlists."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from lease_support import register_test_policy
from capability_runtime.catalog import LifecycleState
from capability_runtime.network import RevocationClosePolicy
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.rpc.dispatcher import RpcDispatcher
from capability_runtime.types import AgentIdentity, CapabilityRef


@pytest.fixture
def runtime(tmp_path):
    register_test_policy("create_pr")
    return CapabilityRuntime(tmp_path / "trace.jsonl", "trace-rpc", 400)


def test_agent_surface_rejects_revoke(runtime):
    dispatcher = RpcDispatcher(
        runtime, surface="agent", bound_agent_id="devcontainer-agent"
    )
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.revoke",
            "params": {"target": "cap-reach-api", "reason": "x"},
        }
    )
    assert "error" in response
    assert response["error"]["code"] == -32601


def test_agent_check_injects_agent_id(runtime):
    dispatcher = RpcDispatcher(
        runtime, surface="agent", bound_agent_id="devcontainer-agent"
    )
    with patch.object(
        runtime, "check_current_capabilities", wraps=runtime.check_current_capabilities
    ) as spy:
        response = dispatcher.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "capability.check",
                "params": {"agent_id": "attacker", "context": {}},
            }
        )
    assert "result" in response
    spy.assert_called_once()
    call_agent_id = spy.call_args[0][0]
    assert call_agent_id == AgentIdentity("devcontainer-agent")


def test_admin_revoke_forwards_close_policy_to_runtime(runtime):
    dispatcher = RpcDispatcher(runtime, surface="admin", bound_agent_id="operator")
    with patch.object(runtime, "revoke_capability", wraps=runtime.revoke_capability) as spy:
        response = dispatcher.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "capability.revoke",
                "params": {
                    "target": "cap-create-pr",
                    "reason": "emergency",
                    "close_policy": "immediate",
                },
            }
        )
    assert "result" in response
    assert response["result"] == {"revoked": True}
    spy.assert_called_once()
    _, kwargs = spy.call_args
    assert kwargs["close_policy"] == RevocationClosePolicy.IMMEDIATE
    assert kwargs["trigger"] == "operator"


def test_admin_revoke_rejects_invalid_close_policy(runtime):
    dispatcher = RpcDispatcher(runtime, surface="admin", bound_agent_id="operator")
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.revoke",
            "params": {
                "target": "cap-create-pr",
                "reason": "x",
                "close_policy": "not-a-policy",
            },
        }
    )
    assert "error" in response
    assert response["error"]["code"] == -32602


def test_admin_surface_allows_revoke(runtime):
    agent = AgentIdentity("devcontainer-agent")
    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "setup lease"
    )

    bundle_before = runtime.check_current_capabilities(agent, {})
    assert "create_pr" in [t.name for t in bundle_before.tools]

    dispatcher = RpcDispatcher(runtime, surface="admin", bound_agent_id="operator")
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "capability.revoke",
            "params": {"target": "cap-create-pr", "reason": "policy"},
        }
    )
    assert "result" in response
    assert "error" not in response

    bundle_after = runtime.check_current_capabilities(agent, {})
    assert "create_pr" not in [t.name for t in bundle_after.tools]


def test_agent_surface_allows_check_lease_discover(runtime):
    dispatcher = RpcDispatcher(
        runtime, surface="agent", bound_agent_id="devcontainer-agent"
    )

    check = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.check",
            "params": {"context": {}},
        }
    )
    assert "result" in check
    assert "tools" in check["result"]

    runtime.catalog.register(
        "find_me", CapabilityRef("cap-find-me"), initial_state=LifecycleState.DISCOVERABLE
    )
    discover = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "capability.discover",
            "params": {"query": "find"},
        }
    )
    assert "result" in discover

    lease = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "capability.lease",
            "params": {
                "capability_ref": "cap-create-pr",
                "justification": "need it",
            },
        }
    )
    assert "result" in lease
    assert "lease_id" in lease["result"]


def test_admin_surface_allows_watch_poll(runtime):
    watcher = MagicMock()
    dispatcher = RpcDispatcher(
        runtime,
        surface="admin",
        bound_agent_id="operator",
        watcher=watcher,
    )
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.watch.poll",
            "params": {},
        }
    )
    assert "result" in response
    watcher.poll_once.assert_called_once()


def test_invalid_request_missing_method(runtime):
    dispatcher = RpcDispatcher(
        runtime, surface="agent", bound_agent_id="devcontainer-agent"
    )
    response = dispatcher.handle({"jsonrpc": "2.0", "id": 1})
    assert response["error"]["code"] == -32600


def test_lease_returns_rpc_error_when_netbird_grant_raises(tmp_path):
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, SyncMode

    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-rpc", 401, netbird_client=client)
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-bad", SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    register_test_policy("reach_api")

    def boom(*_a, **_kw):
        raise RuntimeError("HTTP Error 404: Not Found")

    client.enable_binding = boom  # type: ignore[method-assign]

    dispatcher = RpcDispatcher(runtime, surface="admin", bound_agent_id="operator")
    response = dispatcher.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "capability.lease",
            "params": {
                "agent_id": "devcontainer-agent",
                "capability_ref": "cap-reach-api",
                "justification": "gate",
            },
        }
    )
    assert "error" in response
    assert "404" in response["error"]["message"]
