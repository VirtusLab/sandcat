from __future__ import annotations

from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.errors import CapabilityUnknown
from capability_runtime.lease import LeaseManager
from capability_runtime.types import CapabilityRef, LeaseId


class RevocationManager:
    def __init__(self, catalog: CapabilityCatalog, lease_manager: LeaseManager) -> None:
        self._catalog = catalog
        self._lease_manager = lease_manager
        self._revoked_leases: set[LeaseId] = set()

    def revoke_by_lease(self, lease_id: LeaseId, reason: str) -> None:
        self._revoked_leases.add(lease_id)
        lease = self._lease_manager.get_lease(lease_id)
        if lease is not None:
            self._catalog.set_state(lease.capability_ref, LifecycleState.REVOKED)

    def revoke_by_ref(self, capability_ref: CapabilityRef, reason: str) -> None:
        self._catalog.set_state(capability_ref, LifecycleState.REVOKED)
        for lease_id, lease in self._lease_manager._leases.items():
            if lease.capability_ref == capability_ref:
                self._revoked_leases.add(lease_id)

    def is_revoked(self, capability_ref: CapabilityRef) -> bool:
        try:
            return self._catalog.get_state(capability_ref) == LifecycleState.REVOKED
        except CapabilityUnknown:
            return False

    def is_lease_revoked(self, lease_id: LeaseId) -> bool:
        return lease_id in self._revoked_leases
