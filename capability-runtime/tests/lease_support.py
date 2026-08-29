from __future__ import annotations

from datetime import timedelta

from capability_runtime.policy import LeasePolicy, register_lease_policy


def register_test_policy(
    name: str,
    *,
    quota: int = 1,
    ttl_minutes: int = 10,
    token_budget: int = 25_000,
    risk_envelope: str = "high",
) -> LeasePolicy:
    policy = LeasePolicy(
        quota=quota,
        ttl=timedelta(minutes=ttl_minutes),
        token_budget=token_budget,
        risk_envelope=risk_envelope,
    )
    register_lease_policy(name, policy)
    return policy
