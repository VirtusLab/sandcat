"""Tests for stdio MCP ↔ JSON-RPC bridge."""

from __future__ import annotations

import io
import json
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from capability_runtime.mcp.bridge import run_mcp_bridge
from capability_runtime.rpc.transports.unix import UnixRpcServer


def _wait_for_socket(path: Path, timeout: float = 2.0) -> None:
    import socket

    deadline = time.time() + timeout
    while time.time() < deadline:
        if not path.exists():
            time.sleep(0.01)
            continue
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(0.2)
                sock.connect(str(path))
            return
        except OSError:
            time.sleep(0.01)
    raise TimeoutError(f"socket not ready: {path}")


@pytest.fixture
def mock_dispatcher():
    dispatcher = MagicMock()
    dispatcher.handle.return_value = {
        "jsonrpc": "2.0",
        "result": {
            "agent_id": "devcontainer-agent",
            "tools": [],
            "networks": [],
            "rules": [],
            "skills": [],
            "policies": [],
            "hooks": [],
            "budgets": {},
            "provenance": {},
            "version": 1,
        },
        "id": 1,
    }
    return dispatcher


@pytest.fixture
def rpc_server(tmp_path, mock_dispatcher):
    sock_path = tmp_path / "agent.sock"
    server = UnixRpcServer(sock_path, mock_dispatcher)
    server.start()
    _wait_for_socket(sock_path)
    yield sock_path, mock_dispatcher
    server.stop()


def test_bridge_forwards_tools_call_to_rpc(tmp_path, monkeypatch, rpc_server):
    sock_path, mock_dispatcher = rpc_server
    monkeypatch.setenv("SANDCAT_AGENT_ID", "devcontainer-agent")
    monkeypatch.setenv("CAPABILITY_AGENT_SOCKET", str(sock_path))

    stdin = io.StringIO(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call",'
        '"params":{"name":"capability_check","arguments":{"context":{}}}}\n'
    )
    stdout = io.StringIO()
    run_mcp_bridge(stdin, stdout)

    out = json.loads(stdout.getvalue())
    assert "result" in out
    assert out["result"]["isError"] is False
    mock_dispatcher.handle.assert_called_once()
    request = mock_dispatcher.handle.call_args[0][0]
    assert request["method"] == "capability.check"
    assert request["params"] == {"context": {}}


def test_bridge_initialize_and_tools_list(tmp_path, monkeypatch, rpc_server):
    sock_path, _ = rpc_server
    monkeypatch.setenv("SANDCAT_AGENT_ID", "devcontainer-agent")
    monkeypatch.setenv("CAPABILITY_AGENT_SOCKET", str(sock_path))

    stdin = io.StringIO(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n'
    )
    stdout = io.StringIO()
    run_mcp_bridge(stdin, stdout)

    lines = [json.loads(line) for line in stdout.getvalue().strip().split("\n")]
    assert lines[0]["result"]["protocolVersion"] == "2024-11-05"
    tool_names = {t["name"] for t in lines[1]["result"]["tools"]}
    assert "capability_check" in tool_names


def test_bridge_requires_agent_id(monkeypatch):
    monkeypatch.delenv("SANDCAT_AGENT_ID", raising=False)
    with pytest.raises(RuntimeError, match="SANDCAT_AGENT_ID"):
        run_mcp_bridge(io.StringIO(""), io.StringIO())


def test_bridge_integration_with_daemon(tmp_path, monkeypatch):
    """End-to-end bridge → real daemon agent socket."""
    from capability_runtime.daemon import CapabilityDaemon, DaemonConfig

    catalog = {
        "capabilities": [
            {"name": "create_pr", "ref": "cap-create-pr", "type": "tool"},
        ]
    }
    catalog_path = tmp_path / "catalog.json"
    catalog_path.write_text(json.dumps(catalog))

    sock_dir = tmp_path / "sockets"
    config = DaemonConfig(
        catalog_path=catalog_path,
        agent_socket=sock_dir / "agent.sock",
        admin_socket=sock_dir / "admin.sock",
        trace_file=tmp_path / "trace.jsonl",
        agent_id="devcontainer-agent",
        watch_interval=0.1,
        mock_netbird=True,
    )
    daemon = CapabilityDaemon(config)
    thread = threading.Thread(target=daemon.start, daemon=True)
    thread.start()
    _wait_for_socket(config.agent_socket, timeout=3.0)

    try:
        monkeypatch.setenv("SANDCAT_AGENT_ID", "devcontainer-agent")
        monkeypatch.setenv("CAPABILITY_AGENT_SOCKET", str(config.agent_socket))

        stdin = io.StringIO(
            '{"jsonrpc":"2.0","id":1,"method":"tools/call",'
            '"params":{"name":"capability_check","arguments":{"context":{}}}}\n'
        )
        stdout = io.StringIO()
        run_mcp_bridge(stdin, stdout)

        out = json.loads(stdout.getvalue())
        assert "result" in out
        payload = json.loads(out["result"]["content"][0]["text"])
        assert payload["agent_id"] == "devcontainer-agent"
    finally:
        daemon.stop()
