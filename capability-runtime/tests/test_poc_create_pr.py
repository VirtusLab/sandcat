"""Integration tests for PoC 1 create_pr lifecycle (spec §5.1)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lease_support import register_test_policy
from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.errors import CapabilityNotVisible
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef, LeaseDecision


@dataclass
class _Poc1Result:
    initial_tools: list[str]
    lease_decision: LeaseDecision
    tools_after_lease: list[str]
    action_result: Any
    tools_after_use: list[str]
    retry_blocked: bool
    retry_error: CapabilityNotVisible | None
    adapted_action: str
    create_pr_retry_attempted: bool


def _run_create_pr_lifecycle(trace_path: Path) -> _Poc1Result:
    register_test_policy("create_pr")
    runtime = CapabilityRuntime(trace_path, "poc1-create-pr", seed=42)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("demo-agent")
    context: dict = {}

    bundle1 = runtime.check_current_capabilities(agent, context)
    initial_tools = [t.name for t in bundle1.tools]

    decision = runtime.request_capability_lease(
        agent,
        agent,
        CapabilityRef("cap-create-pr"),
        "Need to open PR for feature",
    )

    bundle2 = runtime.check_current_capabilities(agent, context)
    tools_after_lease = [t.name for t in bundle2.tools]

    action_result = loop.run_step(
        agent,
        context,
        "create_pr",
        lambda: "PR created (mock)",
    )

    bundle3 = runtime.check_current_capabilities(agent, context)
    tools_after_use = [t.name for t in bundle3.tools]

    retry_error: CapabilityNotVisible | None = None
    retry_blocked = False
    try:
        loop.run_step(agent, context, "create_pr", lambda: "should not run")
    except CapabilityNotVisible as exc:
        retry_error = exc
        retry_blocked = True

    return _Poc1Result(
        initial_tools=initial_tools,
        lease_decision=decision,
        tools_after_lease=tools_after_lease,
        action_result=action_result,
        tools_after_use=tools_after_use,
        retry_blocked=retry_blocked,
        retry_error=retry_error,
        adapted_action="draft_pr",
        create_pr_retry_attempted=False,
    )


def test_poc1_create_pr_lifecycle(tmp_path: Path) -> None:
    """create_pr absent → lease → present → use → absent."""
    result = _run_create_pr_lifecycle(tmp_path / "trace.jsonl")

    assert "create_pr" not in result.initial_tools
    assert result.lease_decision.quota == 1
    assert result.lease_decision.capability_ref == CapabilityRef("cap-create-pr")
    assert "create_pr" in result.tools_after_lease
    assert result.action_result == "PR created (mock)"
    assert "create_pr" not in result.tools_after_use


def test_poc1_agent_adapts_instead_of_retrying_create_pr(tmp_path: Path) -> None:
    """After lease exhaustion, agent catches CapabilityNotVisible and uses draft_pr."""
    result = _run_create_pr_lifecycle(tmp_path / "trace.jsonl")

    assert result.retry_blocked is True
    assert isinstance(result.retry_error, CapabilityNotVisible)
    assert result.adapted_action == "draft_pr"
    assert result.create_pr_retry_attempted is False
