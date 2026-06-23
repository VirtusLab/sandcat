"""Lease policy decisions for PoC capabilities (extracted from runtime core)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta


class LeasePolicyNotFound(Exception):
    """No lease policy registered for the given capability name."""


@dataclass(frozen=True)
class LeasePolicy:
    quota: int
    ttl: timedelta
    token_budget: int
    risk_envelope: str


_POC_POLICIES: dict[str, LeasePolicy] = {
    "create_pr": LeasePolicy(
        quota=1,
        ttl=timedelta(minutes=10),
        token_budget=25_000,
        risk_envelope="high",
    ),
    "write_note": LeasePolicy(
        quota=3,
        ttl=timedelta(minutes=5),
        token_budget=10_000,
        risk_envelope="medium",
    ),
}


def lease_policy_for(capability_name: str | None) -> LeasePolicy:
    if capability_name is None:
        raise LeasePolicyNotFound("missing capability name")
    try:
        return _POC_POLICIES[capability_name]
    except KeyError as exc:
        raise LeasePolicyNotFound(capability_name) from exc
