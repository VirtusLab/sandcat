from __future__ import annotations

import logging
import os
from pathlib import Path

from capability_runtime.network import RevocationClosePolicy
from capability_runtime.rpc.transports.unix import UnixRpcClient

logger = logging.getLogger(__name__)

DEFAULT_REVOKE_SOCKET = Path(
    os.environ.get("MITMPROXY_REVOKE_SOCKET", "/mitmproxy-config/l7-revoke.sock")
)


def push_l7_revocation(
    *,
    socket_path: Path,
    host_patterns: list[str],
    close_policy: RevocationClosePolicy,
    drain_seconds: int | None,
    capability_ref: str | None,
    lease_id: str | None,
    reason: str,
    trigger: str,
    timeout: float = 0.5,
) -> bool:
    params = {
        "host_patterns": host_patterns,
        "close_policy": str(close_policy),
        "drain_seconds": drain_seconds,
        "reason": reason,
        "trigger": trigger,
    }
    if capability_ref is not None:
        params["capability_ref"] = capability_ref
    if lease_id is not None:
        params["lease_id"] = lease_id
    try:
        resp = UnixRpcClient(socket_path, timeout=timeout).call(
            "mitmproxy.l7.revoke_flows", params
        )
    except OSError as exc:
        logger.warning("L7 revoke push failed: %s", exc)
        return False
    if "error" in resp:
        logger.warning("L7 revoke push RPC error: %s", resp["error"])
        return False
    return True
