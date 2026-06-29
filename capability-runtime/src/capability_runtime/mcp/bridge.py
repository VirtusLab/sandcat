"""Stdio MCP ↔ JSON-RPC bridge for agent containers."""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable
from typing import Any, TextIO

from capability_runtime.mcp.server import McpServer
from capability_runtime.rpc.transports.stdio_bridge import BridgeRpcClient

DEFAULT_AGENT_SOCKET = "/run/sandcat/capability/agent.sock"


def run_mcp_bridge(
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    *,
    rpc_client: BridgeRpcClient | None = None,
) -> None:
    """Read newline-delimited MCP JSON-RPC from stdin; write responses to stdout."""
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    _require_agent_id()
    client = rpc_client or BridgeRpcClient(_agent_socket_path())
    server = McpServer()

    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            response = {
                "jsonrpc": "2.0",
                "error": {"code": -32700, "message": "Parse error"},
                "id": None,
            }
            _write_response(stdout, response)
            continue

        if not isinstance(request, dict):
            response = {
                "jsonrpc": "2.0",
                "error": {"code": -32600, "message": "Invalid Request"},
                "id": None,
            }
            _write_response(stdout, response)
            continue

        response = server.handle(request, _make_rpc_call(client))
        if response is not None:
            _write_response(stdout, response)


def _make_rpc_call(client: BridgeRpcClient) -> Callable[[str, dict[str, Any]], dict[str, Any]]:
    def rpc_call(method: str, params: dict[str, Any]) -> dict[str, Any]:
        return client.call(method, params)

    return rpc_call


def _write_response(stdout: TextIO, response: dict[str, Any]) -> None:
    stdout.write(json.dumps(response) + "\n")
    stdout.flush()


def _require_agent_id() -> str:
    agent_id = os.environ.get("SANDCAT_AGENT_ID")
    if not agent_id:
        raise RuntimeError("SANDCAT_AGENT_ID environment variable is required")
    return agent_id


def _agent_socket_path() -> str:
    return os.environ.get("CAPABILITY_AGENT_SOCKET", DEFAULT_AGENT_SOCKET)


def main() -> None:
    run_mcp_bridge()


if __name__ == "__main__":
    main()
