"""Mock MCP tool wrapper — transport-agnostic (spec §5.2)."""

from __future__ import annotations

from dataclasses import dataclass

from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.catalog import LifecycleState
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


@dataclass
class McpToolCapability:
    name: str
    ref: CapabilityRef
    description: str


class McpToolAdapter:
    """Wraps MCP-delivered tools in CapabilityBundle surface."""

    def __init__(self, runtime: CapabilityRuntime):
        self._runtime = runtime
        self._side_effects: list[str] = []

    def register_mcp_tool(
        self,
        tool: McpToolCapability,
        initial_state: LifecycleState = LifecycleState.DECLARED,
    ) -> None:
        self._runtime.catalog.register(tool.name, tool.ref, initial_state)

    def invoke(
        self,
        agent_id: AgentIdentity,
        context: dict,
        tool_name: str,
        payload: str,
        loop: AgentExecutionLoop,
    ) -> str:
        def action_fn() -> str:
            side_effect = f"{tool_name}:{payload}"
            self._side_effects.append(side_effect)
            return f"note written: {payload}"

        return loop.run_step(agent_id, context, tool_name, action_fn)

    @property
    def side_effects(self) -> list[str]:
        return list(self._side_effects)
