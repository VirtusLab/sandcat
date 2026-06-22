"""RouteDisappearanceWatcher — detect physical route removal and trigger logical revoke."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from capability_runtime.netbird_client import NetBirdClient
    from capability_runtime.runtime import CapabilityRuntime


class RouteDisappearanceWatcher:
    """Monitor NetBird peers and trigger logical revoke when they disappear.
    
    This watcher detects when a peer (and its associated routes) no longer exist
    in NetBird, typically because they were removed externally via `wg syncconf`
    or NetBird API. When detected, it performs a logical-only revocation since
    the physical resource is already gone.
    """

    def __init__(self, runtime: CapabilityRuntime, client: NetBirdClient):
        """Initialize watcher with runtime and NetBird client.
        
        Args:
            runtime: The capability runtime to revoke from
            client: NetBird client to query current peer state
        """
        self._runtime = runtime
        self._client = client

    def poll_once(self) -> None:
        """Poll once for disappeared peers and revoke their capabilities.
        
        For each network binding registered in the catalog, checks if the
        associated peer_id still exists in NetBird. If not, performs a
        logical-only revocation via runtime.revoke_from_physical().
        """
        # Collect all network bindings from catalog
        bindings_to_revoke = []
        
        for ref in self._runtime.catalog._by_ref:
            binding = self._runtime.catalog.get_network_binding(ref)
            if binding is not None:
                # Check if peer still exists
                if not self._client.peer_exists(binding.peer_id):
                    bindings_to_revoke.append(binding)
        
        # Revoke all disappeared bindings
        for binding in bindings_to_revoke:
            reason = f"peer {binding.peer_id} disappeared from NetBird"
            self._runtime.revoke_from_physical(binding, reason)
