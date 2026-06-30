"""Orchestration helpers for NetBird physical sync during capability grant."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from capability_runtime.network import NetworkBinding
    from capability_runtime.netbird_backend import NetBirdRevocationBackend


def grant_network_binding(
    backend: NetBirdRevocationBackend,
    binding: NetworkBinding,
) -> NetworkBinding:
    """Grant a network binding by enabling it via the NetBird backend.
    
    Args:
        backend: The NetBird revocation backend
        binding: The network binding to grant
        
    Returns:
        The updated binding (may have a new route_id if one was created)
        
    Raises:
        Any exception from enable_binding (caller should handle rollback)
    """
    return backend.grant_binding(binding)
