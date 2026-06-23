"""Tests for PoC lease policy lookup."""

from datetime import timedelta

import pytest

from capability_runtime.policy import LeasePolicyNotFound, lease_policy_for


def test_create_pr_policy():
    policy = lease_policy_for("create_pr")
    assert policy.quota == 1
    assert policy.ttl == timedelta(minutes=10)
    assert policy.token_budget == 25_000
    assert policy.risk_envelope == "high"


def test_write_note_policy():
    policy = lease_policy_for("write_note")
    assert policy.quota == 3
    assert policy.ttl == timedelta(minutes=5)
    assert policy.token_budget == 10_000
    assert policy.risk_envelope == "medium"


def test_unknown_capability_raises():
    with pytest.raises(LeasePolicyNotFound):
        lease_policy_for("unknown_tool")
