from __future__ import annotations

from dataclasses import dataclass

from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.types import AgentIdentity


@dataclass
class DiscoveryIntent:
    query: str


@dataclass
class DiscoveryResult:
    capabilities: list[dict]
    denied: bool


def discover_capabilities(
    catalog: CapabilityCatalog,
    agent_id: AgentIdentity,
    intent: DiscoveryIntent,
) -> DiscoveryResult:
    query = intent.query.lower()
    matches: list[dict] = []

    for ref, state in catalog._by_ref.items():
        if state != LifecycleState.DISCOVERABLE:
            continue
        name = catalog._name_by_ref.get(ref)
        if name is None or query not in name.lower():
            continue
        matches.append(
            {
                "name": name,
                "ref": ref.value,
                "description": "",
            }
        )

    if not matches:
        return DiscoveryResult(capabilities=[], denied=True)
    return DiscoveryResult(capabilities=matches, denied=False)
