"""AgentExecutionLoop — thin harness for check-then-act with bundle version."""

from __future__ import annotations

import threading
from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, LeaseId


class AgentExecutionLoop:
    """Re-fetch bundle before each action; enforce bundle version optimistically."""

    def __init__(self, runtime: CapabilityRuntime):
        self._runtime = runtime
        self._tool_locks: dict[tuple[str, str], threading.Lock] = {}
        self._tool_locks_guard = threading.Lock()

    def _lock_for_tool(self, agent_id: AgentIdentity, tool_name: str) -> threading.Lock:
        key = (agent_id.value, tool_name)
        with self._tool_locks_guard:
            if key not in self._tool_locks:
                self._tool_locks[key] = threading.Lock()
            return self._tool_locks[key]

    def run_step(
        self,
        agent_id: AgentIdentity,
        context: dict,
        tool_name: str,
        action_fn: Callable[[], Any],
        now: datetime | None = None,
    ) -> Any:
        effective_now = now or datetime.now(timezone.utc)
        lock = self._lock_for_tool(agent_id, tool_name)

        with lock:
            bundle = self._runtime.check_current_capabilities(agent_id, context)
            lease_id = _lease_id_for_tool(bundle.tools, tool_name)
            self._runtime.enforce_action(
                agent_id, tool_name, bundle.version, effective_now
            )
            result = action_fn()
            if lease_id is not None:
                self._runtime.record_action(
                    agent_id, agent_id, lease_id, effective_now
                )
            return result


def _lease_id_for_tool(tools, tool_name: str) -> LeaseId | None:
    for tool in tools:
        if tool.name == tool_name:
            return tool.lease_id
    return None
