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


def _push(
    *,
    socket_path: Path,
    method: str,
    params: dict,
    timeout: float,
) -> bool:
    """Best-effort JSON-RPC push to mitmproxy. Never raises.

    The proxy may be absent, restarting, or running without the revoke addon;
    none of those may abort the caller's revoke or grant, which stand on their
    own at the network layer.
    """
    try:
        resp = UnixRpcClient(socket_path, timeout=timeout).call(method, params)
    except Exception as exc:
        logger.warning("L7 push %s failed: %r", method, exc)
        return False
    if "error" in resp:
        logger.warning("L7 push %s RPC error: %s", method, resp["error"])
        return False
    return True


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
    return _push(
        socket_path=socket_path,
        method="mitmproxy.l7.revoke_flows",
        params=params,
        timeout=timeout,
    )


def push_l7_restore(
    *,
    socket_path: Path,
    host_patterns: list[str],
    capability_ref: str | None,
    lease_id: str | None,
    reason: str,
    trigger: str,
    timeout: float = 0.5,
) -> bool:
    """Clear a previous revoke push so a re-granted capability is reachable."""
    params = {
        "host_patterns": host_patterns,
        "reason": reason,
        "trigger": trigger,
    }
    if capability_ref is not None:
        params["capability_ref"] = capability_ref
    if lease_id is not None:
        params["lease_id"] = lease_id
    return _push(
        socket_path=socket_path,
        method="mitmproxy.l7.restore_flows",
        params=params,
        timeout=timeout,
    )
