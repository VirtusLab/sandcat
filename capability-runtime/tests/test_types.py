from datetime import datetime, timezone
from capability_runtime.types import (
    AgentIdentity,
    BudgetEnvelope,
    CapabilityBundle,
    CapabilityRef,
    ProvenanceRecord,
    ToolCapability,
)


def test_capability_bundle_roundtrip():
    now = datetime(2026, 6, 22, 12, 0, 0, tzinfo=timezone.utc)
    bundle = CapabilityBundle(
        agent_id=AgentIdentity("agent-1"),
        issued_at=now,
        expires_at=None,
        tools=[
            ToolCapability(
                ref=CapabilityRef("cap-create-pr"),
                name="create_pr",
                lease_id=None,
                quota="unbounded",
                expires_at=None,
            )
        ],
        rules=[],
        skills=[],
        policies=[],
        hooks=[],
        budgets=BudgetEnvelope(
            token_quota="unbounded",
            action_quota="unbounded",
            wall_time_ttl=None,
        ),
        provenance=ProvenanceRecord(
            issuer="runtime-1",
            policy_version="1.0.0",
            trace_id="trace-abc",
        ),
        version=1,
    )
    assert bundle.agent_id.value == "agent-1"
    assert bundle.tools[0].name == "create_pr"
    assert bundle.version == 1
