"""Tests for minimal MCP server."""

from __future__ import annotations

import json

import pytest

from capability_runtime.mcp.server import McpServer, TOOLS


def _rpc_call(method: str, params: dict) -> dict:
    if method == "capability.check":
        return {"jsonrpc": "2.0", "result": {"agent_id": "test-agent", "tools": []}, "id": 1}
    if method == "capability.lease":
        return {
            "jsonrpc": "2.0",
            "result": {"lease_id": "lease-1", "capability_ref": params["capability_ref"]},
            "id": 1,
        }
    if method == "capability.discover":
        return {"jsonrpc": "2.0", "result": {"capabilities": ["cap-a"], "denied": []}, "id": 1}
    return {"jsonrpc": "2.0", "error": {"code": -32601, "message": "not found"}, "id": 1}


@pytest.fixture
def server():
    return McpServer()


def test_initialize_returns_protocol_version(server):
    response = server.handle(
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        _rpc_call,
    )
    assert response is not None
    assert response["result"]["protocolVersion"] == "2024-11-05"
    assert "serverInfo" in response["result"]


def test_tools_list_returns_meta_tools(server):
    response = server.handle(
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        _rpc_call,
    )
    assert response is not None
    names = {tool["name"] for tool in response["result"]["tools"]}
    assert names == {"capability_check", "capability_lease", "capability_discover"}
    assert len(response["result"]["tools"]) == len(TOOLS)


def test_tools_call_check_forwards_to_rpc(server):
    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "capability_check", "arguments": {"context": {"task": "x"}}},
        },
        _rpc_call,
    )
    assert response is not None
    content = response["result"]["content"][0]["text"]
    payload = json.loads(content)
    assert payload["agent_id"] == "test-agent"
    assert response["result"]["isError"] is False


def test_tools_call_lease_forwards_to_rpc(server):
    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "capability_lease",
                "arguments": {
                    "capability_ref": "cap-create-pr",
                    "justification": "need it",
                },
            },
        },
        _rpc_call,
    )
    assert response is not None
    payload = json.loads(response["result"]["content"][0]["text"])
    assert payload["lease_id"] == "lease-1"


def test_tools_call_discover_forwards_to_rpc(server):
    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {"name": "capability_discover", "arguments": {"query": "pr"}},
        },
        _rpc_call,
    )
    assert response is not None
    payload = json.loads(response["result"]["content"][0]["text"])
    assert payload["capabilities"] == ["cap-a"]


def test_tools_call_unknown_tool(server):
    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": {"name": "unknown_tool", "arguments": {}},
        },
        _rpc_call,
    )
    assert response is not None
    assert response["result"]["isError"] is True


def test_tools_call_rpc_error(server):
    def failing_rpc(method: str, params: dict) -> dict:
        return {"jsonrpc": "2.0", "error": {"code": -32603, "message": "boom"}, "id": 1}

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {"name": "capability_check", "arguments": {"context": {}}},
        },
        failing_rpc,
    )
    assert response is not None
    assert response["result"]["isError"] is True
    assert response["result"]["content"][0]["text"] == "boom"


def test_initialized_notification_returns_none(server):
    response = server.handle(
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        _rpc_call,
    )
    assert response is None


def test_unknown_method_returns_error(server):
    response = server.handle(
        {"jsonrpc": "2.0", "id": 8, "method": "resources/list", "params": {}},
        _rpc_call,
    )
    assert response is not None
    assert response["error"]["code"] == -32601
