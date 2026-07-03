"""RouteDisappearanceWatcher — detect physical route removal and trigger logical revoke."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from capability_runtime.netbird_client import NetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime

from capability_runtime.catalog import LifecycleState
from capability_runtime.network import SyncMode


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

    def _should_watch_binding(self, binding: NetworkBinding) -> bool:
        """Determine if a binding should be watched for route disappearance.
        
        A binding should be watched if:
        - Its catalog state is VISIBLE or LEASED, OR
        - It has an active lease (non-revoked, non-expired, non-exhausted)
        
        DECLARED and DISCOVERABLE bindings are not watched.
        
        Args:
            binding: The network binding to check
            
        Returns:
            True if the binding should be watched
        """
        from datetime import datetime, timezone
        
        # Check catalog state
        try:
            state = self._runtime.catalog.get_state(binding.capability_ref)
            if state in (LifecycleState.VISIBLE, LifecycleState.LEASED):
                return True
        except Exception:
            pass
        
        # Check for active leases
        now = datetime.now(timezone.utc)
        for lease_id, lease in self._runtime.lease_manager._leases.items():
            if lease.capability_ref == binding.capability_ref:
                if (
                    not self._runtime.lease_manager.is_expired(lease_id, now)
                    and not self._runtime.revocation_manager.is_lease_revoked(lease_id)
                    and not self._runtime.lease_manager.is_exhausted(lease_id)
                ):
                    return True
        
        return False

    def poll_once(self) -> None:
        """Poll once for disappeared peers and revoke their capabilities.
        
        For each network binding registered in the catalog, checks if the
        associated peer_id still exists in NetBird. If not, performs a
        logical-only revocation via runtime.revoke_from_physical().
        
        For ROUTE_ENABLE bindings with a route_id, also checks if the route is 
        disabled or missing. If so, performs logical-only revocation.
        """
        # Collect all network bindings from catalog
        bindings_to_revoke = []
        
        for ref in self._runtime.catalog._by_ref:
            binding = self._runtime.catalog.get_network_binding(ref)
            if binding is not None:
                # Only watch bindings that are VISIBLE/LEASED or have active leases
                if not self._should_watch_binding(binding):
                    continue
                    
                # Check if peer still exists
                if not self._client.peer_exists(binding.peer_id):
                    bindings_to_revoke.append(binding)
                    continue
                    
                # For ROUTE_ENABLE mode with a route_id, check route state
                if binding.sync_mode is SyncMode.ROUTE_ENABLE and binding.route_id:
                    route_state = self._client.get_route_state(binding)
                    if route_state in ("disabled", "missing"):
                        bindings_to_revoke.append(binding)
        
        # Deduplicate bindings
        seen = set()
        unique_bindings = []
        for binding in bindings_to_revoke:
            key = (binding.capability_ref, binding.peer_id, binding.network)
            if key not in seen:
                seen.add(key)
                unique_bindings.append(binding)
        
        # Revoke all disappeared bindings
        for binding in unique_bindings:
            reason = f"peer {binding.peer_id} disappeared from NetBird"
            if binding.sync_mode is SyncMode.ROUTE_ENABLE and binding.route_id:
                route_state = self._client.get_route_state(binding)
                if route_state in ("disabled", "missing"):
                    reason = f"route {binding.route_id} is {route_state}"
            self._runtime.revoke_from_physical(binding, reason)
