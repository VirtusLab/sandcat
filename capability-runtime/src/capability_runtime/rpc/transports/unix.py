"""Line-delimited JSON-RPC over AF_UNIX — one request per connection."""

from __future__ import annotations

import json
import os
import socket
import threading
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from capability_runtime.rpc.dispatcher import RpcDispatcher


class UnixRpcServer:
    """Accept AF_UNIX connections, handle one JSON-RPC request per connection."""

    def __init__(
        self,
        socket_path: Path,
        dispatcher: RpcDispatcher,
        *,
        socket_mode: int | None = None,
    ) -> None:
        self._socket_path = socket_path
        self._dispatcher = dispatcher
        self._socket_mode = socket_mode
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._server: socket.socket | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._serve, name="unix-rpc-server", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        server = self._server
        if server is not None:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(0.5)
                    probe.connect(str(self._socket_path))
            except OSError:
                pass
            try:
                server.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        if self._socket_path.exists():
            self._socket_path.unlink(missing_ok=True)

    def _serve(self) -> None:
        self._socket_path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self._socket_path.parent, 0o755)
        if self._socket_path.exists():
            self._socket_path.unlink()

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server = server
        server.bind(str(self._socket_path))
        if self._socket_mode is not None:
            os.chmod(self._socket_path, self._socket_mode)
        server.listen(5)
        server.settimeout(1.0)

        try:
            while not self._stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self._stop_event.is_set():
                        break
                    raise
                handler = threading.Thread(
                    target=self._handle_connection,
                    args=(conn,),
                    daemon=True,
                )
                handler.start()
        finally:
            server.close()
            self._server = None
            if self._socket_path.exists():
                self._socket_path.unlink(missing_ok=True)

    def _handle_connection(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(5.0)
            line = _read_line(conn)
            if line is None:
                return
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                response = {
                    "jsonrpc": "2.0",
                    "error": {"code": -32700, "message": "Parse error"},
                    "id": None,
                }
            else:
                response = self._dispatcher.handle(request)
            conn.sendall((json.dumps(response) + "\n").encode())


class UnixRpcClient:
    """Send a single JSON-RPC request over AF_UNIX and return the response."""

    def __init__(self, socket_path: Path, *, timeout: float = 5.0) -> None:
        self._socket_path = socket_path
        self._timeout = timeout

    def call(
        self,
        method: str,
        params: dict | None = None,
        *,
        request_id: int | str = 1,
    ) -> dict:
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        payload = (json.dumps(request) + "\n").encode()

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(self._timeout)
            sock.connect(str(self._socket_path))
            sock.sendall(payload)
            line = _read_line(sock)
            if line is None:
                raise ConnectionError("no response from RPC server")
            return json.loads(line)


def _read_line(conn: socket.socket) -> str | None:
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
    return data.split(b"\n", 1)[0].decode()
