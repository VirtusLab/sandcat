"""Tests for AgentExecutionLoop harness (spec threat model)."""

from datetime import datetime, timezone

import pytest

from lease_support import register_test_policy
from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.catalog import LifecycleState
from capability_runtime.errors import CapabilityNotVisible
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_run_step_succeeds_when_tool_visible(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-agent-loop-1", 100)
    runtime.catalog.register(
        "list_files", CapabilityRef("cap-list-files"), LifecycleState.VISIBLE
    )

    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("agent-1")
    called: list[bool] = []

    def action_fn():
        called.append(True)
        return "ok"

    result = loop.run_step(agent, {}, "list_files", action_fn)
    assert result == "ok"
    assert called == [True]


def test_run_step_raises_not_visible(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-agent-loop-2", 101)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("agent-2")

    with pytest.raises(CapabilityNotVisible):
        loop.run_step(agent, {}, "create_pr", lambda: None)


def test_run_step_adapts_after_lease_exhausted(tmp_path):
    register_test_policy("create_pr")
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-agent-loop-3", 102)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("agent-3")

    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "Need create_pr once"
    )

    assert loop.run_step(agent, {}, "create_pr", lambda: "first") == "first"

    with pytest.raises(CapabilityNotVisible):
        loop.run_step(agent, {}, "create_pr", lambda: "second")


def test_run_step_checks_bundle_before_action(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-agent-loop-4", 103)
    runtime.catalog.register(
        "visible_tool", CapabilityRef("cap-visible"), LifecycleState.VISIBLE
    )

    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("agent-4")
    call_order: list[str] = []

    original_check = runtime.check_current_capabilities
    original_enforce = runtime.enforce_action

    def spy_check(*args, **kwargs):
        call_order.append("check")
        return original_check(*args, **kwargs)

    def spy_enforce(*args, **kwargs):
        call_order.append("enforce")
        return original_enforce(*args, **kwargs)

    runtime.check_current_capabilities = spy_check  # type: ignore[method-assign]
    runtime.enforce_action = spy_enforce  # type: ignore[method-assign]

    loop.run_step(agent, {}, "visible_tool", lambda: None)
    assert call_order == ["check", "enforce"]
