"""Tests for JSON-RPC dispatcher with agent/admin surface allowlists."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from capability_runtime.catalog import LifecycleState
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.rpc.dispatcher import RpcDispatcher
from capability_runtime.types import AgentIdentity, CapabilityRef


@pytest.fixture
def runtime(tmp_path):
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
