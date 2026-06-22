from __future__ import annotations

from datetime import datetime, timedelta
from uuid import uuid4

from capability_runtime.errors import LeaseQuotaExceeded
from capability_runtime.types import (
    AgentIdentity,
    CapabilityRef,
    LeaseDecision,
    LeaseId,
)


class LeaseManager:
    def __init__(self) -> None:
        self._leases: dict[LeaseId, LeaseDecision] = {}
        self._remaining_quota: dict[LeaseId, int] = {}

    def grant(
        self,
        agent_id: AgentIdentity,
        capability_ref: CapabilityRef,
        quota: int,
        ttl: timedelta,
        token_budget: int,
        risk_envelope: str,
        now: datetime,
    ) -> LeaseDecision:
        lease_id = LeaseId(str(uuid4()))
        decision = LeaseDecision(
            lease_id=lease_id,
            capability_ref=capability_ref,
            agent_id=agent_id,
            quota=quota,
            token_budget=token_budget,
            risk_envelope=risk_envelope,
            expires_at=now + ttl,
            granted_at=now,
        )
        self._leases[lease_id] = decision
        self._remaining_quota[lease_id] = quota
        return decision

    def decrement_quota(self, lease_id: LeaseId, now: datetime) -> int:
        decision = self._leases[lease_id]
        remaining = self._remaining_quota[lease_id]
        if remaining == 0:
            raise LeaseQuotaExceeded(decision.capability_ref, lease_id)
        remaining -= 1
        self._remaining_quota[lease_id] = remaining
        return remaining

    def is_exhausted(self, lease_id: LeaseId) -> bool:
        return self._remaining_quota.get(lease_id, 0) == 0

    def is_expired(self, lease_id: LeaseId, now: datetime) -> bool:
        decision = self._leases.get(lease_id)
        if decision is None:
            return True
        return now >= decision.expires_at

    def get_lease(self, lease_id: LeaseId) -> LeaseDecision | None:
        return self._leases.get(lease_id)
