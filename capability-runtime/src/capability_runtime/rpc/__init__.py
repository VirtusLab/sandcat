"""JSON-RPC dispatcher for capability runtime."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from capability_runtime.rpc.dispatcher import RpcDispatcher

__all__ = ["RpcDispatcher"]


def __getattr__(name: str) -> Any:
    """Resolve ``RpcDispatcher`` on first use (PEP 562).

    The dispatcher imports ``CapabilityRuntime``, and the runtime imports the
    Unix RPC client from this package's ``transports`` subpackage. Re-exporting
    eagerly would close that loop and break ``import capability_runtime``.
    """
    if name == "RpcDispatcher":
        from capability_runtime.rpc.dispatcher import RpcDispatcher

        return RpcDispatcher
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
