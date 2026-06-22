from datetime import datetime, timedelta, timezone

from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.lease import LeaseManager
from capability_runtime.revoke import RevocationManager
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_revoke_by_ref_sets_revoked_state():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref, initial_state=LifecycleState.VISIBLE)
    lease_mgr = LeaseManager()
    revoke_mgr = RevocationManager(catalog, lease_mgr)

    revoke_mgr.revoke_by_ref(ref, reason="policy violation")

    assert revoke_mgr.is_revoked(ref)
    assert catalog.get_state(ref) == LifecycleState.REVOKED
    assert not catalog.is_visible(ref)


def test_revoke_by_lease_marks_lease_revoked():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref, initial_state=LifecycleState.LEASED)
    lease_mgr = LeaseManager()
    now = datetime(2026, 6, 22, 12, 0, 0, tzinfo=timezone.utc)
    decision = lease_mgr.grant(
        agent_id=AgentIdentity("agent-1"),
        capability_ref=ref,
        quota=1,
        ttl=timedelta(minutes=10),
        token_budget=25000,
        risk_envelope="high",
        now=now,
    )
    revoke_mgr = RevocationManager(catalog, lease_mgr)

    revoke_mgr.revoke_by_lease(decision.lease_id, reason="quota abuse")

    assert revoke_mgr.is_lease_revoked(decision.lease_id)
    assert revoke_mgr.is_revoked(ref)
    assert catalog.get_state(ref) == LifecycleState.REVOKED
