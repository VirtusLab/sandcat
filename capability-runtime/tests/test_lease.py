from datetime import datetime, timedelta, timezone

import pytest

from capability_runtime.errors import LeaseQuotaExceeded
from capability_runtime.lease import LeaseManager
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_grant_lease_and_decrement_quota():
    mgr = LeaseManager()
    now = datetime(2026, 6, 22, 12, 0, 0, tzinfo=timezone.utc)
    decision = mgr.grant(
        agent_id=AgentIdentity("agent-1"),
        capability_ref=CapabilityRef("cap-create-pr"),
        quota=1,
        ttl=timedelta(minutes=10),
        token_budget=25000,
        risk_envelope="high",
        now=now,
    )
    assert decision.quota == 1
    assert decision.token_budget == 25000
    assert decision.risk_envelope == "high"
    assert decision.expires_at == now + timedelta(minutes=10)
    remaining = mgr.decrement_quota(decision.lease_id, now=now)
    assert remaining == 0
    assert mgr.is_exhausted(decision.lease_id)


def test_decrement_raises_when_exhausted():
    mgr = LeaseManager()
    now = datetime(2026, 6, 22, 12, 0, 0, tzinfo=timezone.utc)
    decision = mgr.grant(
        agent_id=AgentIdentity("agent-1"),
        capability_ref=CapabilityRef("cap-x"),
        quota=1,
        ttl=timedelta(minutes=5),
        token_budget=1000,
        risk_envelope="low",
        now=now,
    )
    mgr.decrement_quota(decision.lease_id, now=now)
    with pytest.raises(LeaseQuotaExceeded):
        mgr.decrement_quota(decision.lease_id, now=now)


def test_is_expired():
    mgr = LeaseManager()
    start = datetime(2026, 6, 22, 12, 0, 0, tzinfo=timezone.utc)
    decision = mgr.grant(
        agent_id=AgentIdentity("agent-1"),
        capability_ref=CapabilityRef("cap-x"),
        quota=3,
        ttl=timedelta(minutes=5),
        token_budget=1000,
        risk_envelope="medium",
        now=start,
    )
    assert not mgr.is_expired(decision.lease_id, start + timedelta(minutes=4))
    assert mgr.is_expired(decision.lease_id, start + timedelta(minutes=6))
