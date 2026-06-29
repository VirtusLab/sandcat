"""Unix-socket JSON-RPC client for the agent MCP stdio bridge."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from capability_runtime.rpc.transports.unix import UnixRpcClient


class BridgeRpcClient:
    """Forward JSON-RPC requests to the capability agent socket."""

    def __init__(self, socket_path: Path | str, *, timeout: float = 5.0) -> None:
        self._client = UnixRpcClient(Path(socket_path), timeout=timeout)

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        request_id: int | str = 1,
    ) -> dict[str, Any]:
        return self._client.call(method, params, request_id=request_id)
