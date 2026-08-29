"""Integration tests for the capability sidecar daemon."""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from capability_runtime.daemon import CapabilityDaemon, DaemonConfig, load_catalog_into_runtime
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.rpc.transports.unix import UnixRpcClient
from capability_runtime.runtime import CapabilityRuntime


@pytest.fixture
def catalog_file(tmp_path):
    catalog = {
        "capabilities": [
            {
                "name": "create_pr",
                "ref": "cap-create-pr",
                "type": "tool",
                "lease_policy": {
                    "quota": 1,
                    "ttl_minutes": 10,
                    "token_budget": 25000,
                    "risk_envelope": "high",
                },
            },
            {
                "name": "reach_api",
                "ref": "cap-reach-api",
                "type": "network",
                "peer_id": "peer-test",
                "network": "10.8.0.0/24",
                "route_id": "route-test",
                "lease_policy": {
                    "quota": 1,
                    "ttl_minutes": 10,
                    "token_budget": 25000,
                    "risk_envelope": "high",
                },
            },
        ]
    }
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps(catalog))
    return path


def _wait_for_socket(path: Path, timeout: float = 3.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise TimeoutError(f"socket not ready: {path}")


@pytest.fixture
def daemon(tmp_path, catalog_file):
    sock_dir = tmp_path / "sockets"
    config = DaemonConfig(
        catalog_path=catalog_file,
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
    _wait_for_socket(config.agent_socket)
    _wait_for_socket(config.admin_socket)
    yield daemon, config
    daemon.stop()


def test_load_catalog_registers_tool_and_network(tmp_path, catalog_file):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-catalog", 1)
    load_catalog_into_runtime(runtime, catalog_file)
    assert runtime.catalog.get_by_name("create_pr") is not None
    assert runtime.catalog.get_by_name("reach_api") is not None
    binding = runtime.catalog.get_network_binding(runtime.catalog.get_by_name("reach_api"))
    assert binding is not None
    assert binding.peer_id == "peer-test"


def test_daemon_agent_socket_roundtrip(daemon):
    _, config = daemon
    client = UnixRpcClient(config.agent_socket)
    response = client.call("capability.check", {"context": {}})
    assert "result" in response
    assert "tools" in response["result"]
    assert response["result"]["agent_id"] == "devcontainer-agent"


def test_daemon_agent_lease_via_socket(daemon):
    _, config = daemon
    client = UnixRpcClient(config.agent_socket)
    lease = client.call(
        "capability.lease",
        {"capability_ref": "cap-create-pr", "justification": "integration test"},
    )
    assert "result" in lease
    assert "lease_id" in lease["result"]

    check = client.call("capability.check", {"context": {}})
    tool_names = [tool["name"] for tool in check["result"]["tools"]]
    assert "create_pr" in tool_names


def test_daemon_admin_revoke_via_socket(daemon):
    _, config = daemon
    agent = UnixRpcClient(config.agent_socket)
    admin = UnixRpcClient(config.admin_socket)

    agent.call(
        "capability.lease",
        {"capability_ref": "cap-create-pr", "justification": "to revoke"},
    )
    revoke = admin.call(
        "capability.revoke",
        {"target": "cap-create-pr", "reason": "policy"},
    )
    assert revoke["result"]["revoked"] is True

    check = agent.call("capability.check", {"context": {}})
    tool_names = [tool["name"] for tool in check["result"]["tools"]]
    assert "create_pr" not in tool_names


def test_daemon_agent_rejects_revoke(daemon):
    _, config = daemon
    client = UnixRpcClient(config.agent_socket)
    response = client.call(
        "capability.revoke",
        {"target": "cap-create-pr", "reason": "forged"},
    )
    assert "error" in response
    assert response["error"]["code"] == -32601


def test_daemon_admin_watch_poll(daemon):
    _, config = daemon
    admin = UnixRpcClient(config.admin_socket)
    response = admin.call("capability.watch.poll", {})
    assert response["result"]["polled"] is True


def test_daemon_watcher_revokes_disappeared_peer(daemon):
    daemon_obj, config = daemon
    runtime = daemon_obj.runtime
    client = MockNetBirdClient(
        peers=[{"id": "peer-test", "connected": True}],
        routes=[],
    )
    runtime._netbird_client = client
    daemon_obj._watcher._client = client

    from capability_runtime.catalog import LifecycleState

    ref = runtime.catalog.get_by_name("reach_api")
    runtime.catalog.set_state(ref, LifecycleState.VISIBLE)

    agent = UnixRpcClient(config.agent_socket)
    before = agent.call("capability.check", {"context": {}})
    assert "reach_api" in [n["name"] for n in before["result"]["networks"]]

    client.remove_peer("peer-test")
    admin = UnixRpcClient(config.admin_socket)
    admin.call("capability.watch.poll", {})

    after = agent.call("capability.check", {"context": {}})
    assert "reach_api" not in [n["name"] for n in after["result"]["networks"]]
