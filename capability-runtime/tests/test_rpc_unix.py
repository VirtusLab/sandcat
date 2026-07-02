"""Tests for AF_UNIX JSON-RPC transport."""

from __future__ import annotations

import json
import time
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from capability_runtime.rpc.transports.unix import UnixRpcClient, UnixRpcServer


@pytest.fixture
def mock_dispatcher():
    dispatcher = MagicMock()
    dispatcher.handle.return_value = {
        "jsonrpc": "2.0",
        "result": {"ok": True},
        "id": 1,
    }
    return dispatcher


def _wait_for_socket(path: Path, timeout: float = 2.0) -> None:
    import socket

    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                    sock.settimeout(0.1)
                    sock.connect(str(path))
                    return
            except (ConnectionRefusedError, OSError):
                pass
        time.sleep(0.01)
    raise TimeoutError(f"socket not ready: {path}")


def test_server_handles_single_request(tmp_path, mock_dispatcher):
    sock_path = tmp_path / "test.sock"
    server = UnixRpcServer(sock_path, mock_dispatcher)
    server.start()
    try:
        _wait_for_socket(sock_path)
        client = UnixRpcClient(sock_path)
        response = client.call("capability.check", {"context": {}})
        assert response["result"] == {"ok": True}
        mock_dispatcher.handle.assert_called_once()
        request = mock_dispatcher.handle.call_args[0][0]
        assert request["method"] == "capability.check"
        assert request["params"] == {"context": {}}
    finally:
        server.stop()


def test_one_request_per_connection(tmp_path, mock_dispatcher):
    sock_path = tmp_path / "test.sock"
    server = UnixRpcServer(sock_path, mock_dispatcher)
    server.start()
    try:
        _wait_for_socket(sock_path)
        client = UnixRpcClient(sock_path)
        client.call("capability.check", {"context": {}})
        client.call("capability.lease", {"capability_ref": "cap-x", "justification": "x"})
        assert mock_dispatcher.handle.call_count == 2
    finally:
        server.stop()


def test_invalid_json_returns_parse_error(tmp_path, mock_dispatcher):
    sock_path = tmp_path / "test.sock"
    server = UnixRpcServer(sock_path, mock_dispatcher)
    server.start()
    try:
        _wait_for_socket(sock_path)
        import socket

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(str(sock_path))
            sock.sendall(b"not-json\n")
            data = sock.recv(4096)
        response = json.loads(data.decode().split("\n", 1)[0])
        assert response["error"]["code"] == -32700
        mock_dispatcher.handle.assert_not_called()
    finally:
        server.stop()


def test_socket_mode_allows_non_owner_connect(tmp_path, mock_dispatcher):
    sock_path = tmp_path / "agent.sock"
    server = UnixRpcServer(sock_path, mock_dispatcher, socket_mode=0o666)
    server.start()
    try:
        _wait_for_socket(sock_path)
        assert oct(sock_path.stat().st_mode & 0o777) == "0o666"
        client = UnixRpcClient(sock_path)
        response = client.call("capability.check", {"context": {}})
        assert response["result"] == {"ok": True}
    finally:
        server.stop()

