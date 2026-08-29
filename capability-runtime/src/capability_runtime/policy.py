"""Lease policy lookup. Policies come from the catalog via register_lease_policy."""

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


_LEASE_POLICIES: dict[str, LeasePolicy] = {}


def register_lease_policy(capability_name: str, policy: LeasePolicy) -> None:
    _LEASE_POLICIES[capability_name] = policy


def clear_lease_policies() -> None:
    _LEASE_POLICIES.clear()


def lease_policy_for(capability_name: str | None) -> LeasePolicy:
    if capability_name is None:
        raise LeasePolicyNotFound("missing capability name")
    try:
        return _LEASE_POLICIES[capability_name]
    except KeyError as exc:
        raise LeasePolicyNotFound(capability_name) from exc
