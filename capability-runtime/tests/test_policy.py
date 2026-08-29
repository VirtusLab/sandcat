"""Tests for catalog/register lease policy lookup."""

from datetime import timedelta

import pytest

from capability_runtime.policy import (
    LeasePolicy,
    LeasePolicyNotFound,
    lease_policy_for,
    register_lease_policy,
)
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_unregistered_name_raises():
    with pytest.raises(LeasePolicyNotFound):
        lease_policy_for("create_pr")


def test_register_then_lookup():
    register_lease_policy(
        "reach_api",
        LeasePolicy(
            quota=5,
            ttl=timedelta(minutes=15),
            token_budget=10_000,
            risk_envelope="medium",
        ),
    )
    policy = lease_policy_for("reach_api")
    assert policy.quota == 5
    assert policy.ttl == timedelta(minutes=15)
    assert policy.token_budget == 10_000
    assert policy.risk_envelope == "medium"


def test_missing_capability_name_raises():
    with pytest.raises(LeasePolicyNotFound):
        lease_policy_for(None)


def test_lease_without_registered_policy_fails_closed(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-policy", 1)
    agent = AgentIdentity("agent-1")
    with pytest.raises(LeasePolicyNotFound):
        runtime.request_capability_lease(
            agent, agent, CapabilityRef("cap-create-pr"), "no policy"
        )
