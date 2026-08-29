from __future__ import annotations

import json
import socket
import threading
from pathlib import Path

import pytest

from capability_runtime.policy import clear_lease_policies


@pytest.fixture(autouse=True)
def _reset_lease_policies():
    clear_lease_policies()
    yield
    clear_lease_policies()


class FakeRevokePeer:
    """Stand-in for the mitmproxy revoke addon on an AF_UNIX JSON-RPC socket.

    Binds and listens on the calling thread so ``start()`` returning means the
    socket accepts connections. Tests must not wait on the socket *file*: it
    exists from ``bind()`` onward, i.e. before ``listen()``, so a connect that
    wins that race fails with ECONNREFUSED.
    """

    def __init__(self, socket_path: Path, *, expected: int = 1) -> None:
        self.socket_path = Path(socket_path)
        self.requests: list[dict] = []
        self._expected = expected
        self._ready = threading.Event()
        self._done = threading.Event()
        self._stop = threading.Event()
        self._server: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> FakeRevokePeer:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.socket_path))
        server.listen(8)
        server.settimeout(0.1)
        self._server = server
        self._ready.set()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def wait_ready(self, timeout: float = 2.0) -> bool:
        return self._ready.wait(timeout)

    def wait(self, timeout: float = 2.0) -> list[dict]:
        """Block until the expected number of requests arrived; return them."""
        self._done.wait(timeout)
        return self.requests

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        if self._server is not None:
            self._server.close()
            self._server = None
        self.socket_path.unlink(missing_ok=True)

    def _serve(self) -> None:
        try:
            while len(self.requests) < self._expected and not self._stop.is_set():
                try:
                    conn, _ = self._server.accept()
                except (socket.timeout, TimeoutError):
                    continue
                except OSError:
                    break
                with conn:
                    request = _read_request(conn)
                    if request is None:
                        continue
                    self.requests.append(request)
                    conn.sendall(b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n')
        finally:
            self._done.set()


def _read_request(conn: socket.socket) -> dict | None:
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
    return json.loads(data.split(b"\n", 1)[0])


@pytest.fixture
def revoke_peer(tmp_path):
    """Factory for :class:`FakeRevokePeer`s, stopped at test teardown."""
    peers: list[FakeRevokePeer] = []

    def _make(*, expected: int = 1, name: str = "l7-revoke.sock") -> FakeRevokePeer:
        peer = FakeRevokePeer(tmp_path / name, expected=expected).start()
        assert peer.wait_ready(2) is True
        peers.append(peer)
        return peer

    yield _make

    for peer in peers:
        peer.stop()
