"""AgentExecutionLoop — thin harness for check-then-act with bundle version."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, LeaseId


class AgentExecutionLoop:
    """Re-fetch bundle before each action; enforce bundle version optimistically."""

    def __init__(self, runtime: CapabilityRuntime):
        self._runtime = runtime

    def run_step(
        self,
        agent_id: AgentIdentity,
        context: dict,
        tool_name: str,
        action_fn: Callable[[], Any],
        now: datetime | None = None,
    ) -> Any:
        effective_now = now or datetime.now(timezone.utc)

        bundle = self._runtime.check_current_capabilities(agent_id, context)
        self._runtime.enforce_action(agent_id, tool_name, bundle.version, effective_now)

        result = action_fn()

        lease_id = _lease_id_for_tool(bundle.tools, tool_name)
        if lease_id is not None:
            self._runtime.record_action(lease_id, effective_now)

        return result


def _lease_id_for_tool(tools, tool_name: str) -> LeaseId | None:
    for tool in tools:
        if tool.name == tool_name:
            return tool.lease_id
    return None
