"""Map L7 flow observations to network lease quota decrements."""

from __future__ import annotations

import ipaddress
from datetime import datetime, timezone
from typing import Any

from capability_runtime.catalog import LifecycleState
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, LeaseId


def _host_in_binding_network(host: str, network: str) -> bool:
    try:
        addr = ipaddress.ip_address(host)
        net = ipaddress.ip_network(network, strict=False)
        return addr in net
    except ValueError:
        return False


def _is_billable_l7_status(status: int) -> bool:
    return 200 <= status < 300


def _find_active_network_lease_for_host(
    runtime: CapabilityRuntime,
    agent_id: AgentIdentity,
    host: str,
    now: datetime,
) -> LeaseId | None:
    is_revoked = runtime.revocation_manager.is_lease_revoked
    for lease_id, lease in runtime.lease_manager.iter_active_leases_for_agent(
        agent_id, now, is_revoked=is_revoked
    ):
        binding = runtime.catalog.get_network_binding(lease.capability_ref)
        if binding is None:
            continue
        if not _host_in_binding_network(host, binding.network):
            continue

        state = runtime.catalog.get_state(lease.capability_ref)
        if state != LifecycleState.LEASED:
            continue

        return lease_id

    return None


def record_l7_flow(
    runtime: CapabilityRuntime,
    agent: AgentIdentity,
    *,
    host: str,
    method: str,
    status: int,
    trace_id: str | None = None,
) -> bool:
    """Record an L7 flow against a matching network lease quota.

    Returns True when a matching active lease was found and quota decremented.
    Successful HTTP responses (2xx) decrement quota; other statuses are logged only.
    """
    now = datetime.now(timezone.utc)
    billable = _is_billable_l7_status(status)
    lease_id = (
        _find_active_network_lease_for_host(runtime, agent, host, now)
        if billable
        else None
    )

    event: dict[str, Any] = {
        "event": "l7_flow",
        "agent_id": agent.value,
        "host": host,
        "method": method,
        "status": status,
    }
    if trace_id is not None:
        event["trace_id"] = trace_id
    if lease_id is not None:
        event["lease_id"] = lease_id.value

    runtime.observability.emit_capability_event(event)

    if not billable or lease_id is None:
        return False

    runtime.record_action(agent, agent, lease_id, now)
    return True
