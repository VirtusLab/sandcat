from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Literal, Union

Quota = Union[int, Literal["unbounded"]]


@dataclass(frozen=True)
class AgentIdentity:
    value: str


@dataclass(frozen=True)
class CapabilityRef:
    value: str


@dataclass(frozen=True)
class LeaseId:
    value: str


@dataclass
class ToolCapability:
    ref: CapabilityRef
    name: str
    lease_id: LeaseId | None
    quota: Quota
    expires_at: datetime | None


@dataclass
class RuleCapability:
    ref: CapabilityRef
    name: str
    lease_id: LeaseId | None


@dataclass
class SkillCapability:
    ref: CapabilityRef
    name: str
    lease_id: LeaseId | None


@dataclass
class PolicyCapability:
    ref: CapabilityRef
    name: str
    lease_id: LeaseId | None


@dataclass
class HookCapability:
    ref: CapabilityRef
    name: str
    lease_id: LeaseId | None


@dataclass
class BudgetEnvelope:
    token_quota: Quota
    action_quota: Quota
    wall_time_ttl: timedelta | None


@dataclass
class ProvenanceRecord:
    issuer: str
    policy_version: str
    trace_id: str


@dataclass
class CapabilityBundle:
    agent_id: AgentIdentity
    issued_at: datetime
    expires_at: datetime | None
    tools: list[ToolCapability]
    rules: list[RuleCapability]
    skills: list[SkillCapability]
    policies: list[PolicyCapability]
    hooks: list[HookCapability]
    budgets: BudgetEnvelope
    provenance: ProvenanceRecord
    version: int = field(default=1)
