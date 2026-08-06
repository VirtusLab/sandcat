from __future__ import annotations

import json
import socket
import threading
import time
from pathlib import Path

from capability_runtime.l7_revoke_push import push_l7_revocation
from capability_runtime.network import RevocationClosePolicy


def _serve_one(sock_path: Path, box: dict) -> None:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    srv.listen(1)
    srv.settimeout(2)
    conn, _ = srv.accept()
    with conn:
        data = b""
        while b"\n" not in data:
            data += conn.recv(4096)
        req = json.loads(data.split(b"\n", 1)[0])
        box["req"] = req
        conn.sendall(b'{"jsonrpc":"2.0","id":1,"result":{"revoked":true}}\n')
    srv.close()


def test_push_sends_mitmproxy_l7_revoke_flows(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    box: dict = {}
    t = threading.Thread(target=_serve_one, args=(sock_path, box), daemon=True)
    t.start()
    for _ in range(50):
        if sock_path.exists():
            break
        time.sleep(0.01)
    ok = push_l7_revocation(
        socket_path=sock_path,
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.IMMEDIATE,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="operator revoke",
        trigger="operator",
    )
    t.join(timeout=2)
    assert ok is True
    assert box["req"]["method"] == "mitmproxy.l7.revoke_flows"
    assert box["req"]["params"]["host_patterns"] == ["10.8.0.0/24"]
    assert box["req"]["params"]["close_policy"] == "immediate"


def test_push_unreachable_returns_false(tmp_path):
    ok = push_l7_revocation(
        socket_path=tmp_path / "missing.sock",
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.DRAIN,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="quota exhausted",
        trigger="quota_exhausted",
    )
    assert ok is False
