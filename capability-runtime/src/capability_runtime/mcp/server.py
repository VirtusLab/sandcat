"""Minimal MCP JSON-RPC subset: initialize, tools/list, tools/call."""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "capability-runtime", "version": "0.1.0"}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "capability_check",
        "description": "Return the agent's current capability bundle.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "context": {"type": "object", "description": "Execution context"},
            },
        },
    },
    {
        "name": "capability_lease",
        "description": "Request a lease for a capability.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "capability_ref": {"type": "string"},
                "justification": {"type": "string"},
            },
            "required": ["capability_ref", "justification"],
        },
    },
    {
        "name": "capability_discover",
        "description": "Discover capabilities matching a query.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
            },
            "required": ["query"],
        },
    },
]

_TOOL_TO_RPC: dict[str, str] = {
    "capability_check": "capability.check",
    "capability_lease": "capability.lease",
    "capability_discover": "capability.discover",
}


RpcCall = Callable[[str, dict[str, Any]], dict[str, Any]]


class McpServer:
    """Handle MCP requests and forward tool calls to capability JSON-RPC."""

    def handle(self, request: dict[str, Any], rpc_call: RpcCall) -> dict[str, Any] | None:
        """Handle one MCP JSON-RPC request. Returns None for notifications."""
        request_id = request.get("id")
        if request.get("jsonrpc") != "2.0":
            return _error_response(request_id, -32600, "Invalid Request")

        method = request.get("method")
        if not isinstance(method, str):
            return _error_response(request_id, -32600, "Invalid Request")

        if method == "notifications/initialized" or method == "initialized":
            return None

        params = request.get("params") or {}
        if not isinstance(params, dict):
            return _error_response(request_id, -32602, "Invalid params")

        if method == "initialize":
            return _success_response(request_id, _handle_initialize())
        if method == "tools/list":
            return _success_response(request_id, {"tools": TOOLS})
        if method == "tools/call":
            return _success_response(request_id, _handle_tools_call(params, rpc_call))

        return _error_response(request_id, -32601, f"Method not found: {method}")


def _handle_initialize() -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {"tools": {}},
        "serverInfo": SERVER_INFO,
    }


def _handle_tools_call(params: dict[str, Any], rpc_call: RpcCall) -> dict[str, Any]:
    name = params.get("name")
    if not isinstance(name, str) or name not in _TOOL_TO_RPC:
        return {
            "content": [{"type": "text", "text": f"Unknown tool: {name!r}"}],
            "isError": True,
        }

    arguments = params.get("arguments") or {}
    if not isinstance(arguments, dict):
        return {
            "content": [{"type": "text", "text": "arguments must be an object"}],
            "isError": True,
        }

    rpc_method = _TOOL_TO_RPC[name]
    rpc_params = _map_tool_arguments(name, arguments)
    rpc_response = rpc_call(rpc_method, rpc_params)

    if "error" in rpc_response:
        error = rpc_response["error"]
        message = error.get("message", "RPC error")
        return {
            "content": [{"type": "text", "text": message}],
            "isError": True,
        }

    result = rpc_response.get("result", rpc_response)
    return {
        "content": [{"type": "text", "text": json.dumps(result)}],
        "isError": False,
    }


def _map_tool_arguments(tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if tool_name == "capability_check":
        return {"context": arguments.get("context", {})}
    if tool_name == "capability_lease":
        return {
            "capability_ref": arguments["capability_ref"],
            "justification": arguments["justification"],
        }
    if tool_name == "capability_discover":
        return {"query": arguments["query"]}
    raise ValueError(f"unmapped tool: {tool_name}")


def _success_response(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "result": result, "id": request_id}


def _error_response(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": request_id,
    }
