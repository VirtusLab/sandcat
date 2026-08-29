"""Tests for McpToolAdapter (spec §5.2)."""

from datetime import timedelta

import pytest

from lease_support import register_test_policy
from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.catalog import LifecycleState
from capability_runtime.errors import CapabilityNotVisible
from capability_runtime.mcp_adapter import McpToolAdapter, McpToolCapability
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def _adapter_and_loop(tmp_path):
    register_test_policy(
        "write_note",
        quota=3,
        ttl_minutes=5,
        token_budget=10_000,
        risk_envelope="medium",
    )
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-mcp-1", 200)
    adapter = McpToolAdapter(runtime)
    adapter.register_mcp_tool(
        McpToolCapability(
            name="write_note",
            ref=CapabilityRef("cap-write-note"),
            description="Write a note to the workspace",
        )
    )
    loop = AgentExecutionLoop(runtime)
    return runtime, adapter, loop


def test_write_note_invisible_until_leased(tmp_path):
    runtime, adapter, _loop = _adapter_and_loop(tmp_path)
    agent = AgentIdentity("agent-mcp-1")
    ctx = {}

    bundle1 = runtime.check_current_capabilities(agent, ctx)
    assert "write_note" not in [t.name for t in bundle1.tools]

    decision = runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-write-note"), "Need to record findings"
    )
    assert decision.quota == 3
    assert decision.token_budget == 10_000
    assert decision.risk_envelope == "medium"
    assert decision.expires_at - decision.granted_at == timedelta(minutes=5)

    bundle2 = runtime.check_current_capabilities(agent, ctx)
    write_note_tools = [t for t in bundle2.tools if t.name == "write_note"]
    assert len(write_note_tools) == 1
    assert write_note_tools[0].lease_id is not None


def test_write_note_lifecycle_quota_3(tmp_path):
    runtime, adapter, loop = _adapter_and_loop(tmp_path)
    agent = AgentIdentity("agent-mcp-2")
    ctx = {}

    assert "write_note" not in [
        t.name for t in runtime.check_current_capabilities(agent, ctx).tools
    ]

    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-write-note"), "Need notes for session"
    )

    for i in range(3):
        result = adapter.invoke(agent, ctx, "write_note", f"note-{i}", loop)
        assert result == f"note written: note-{i}"

    with pytest.raises(CapabilityNotVisible):
        adapter.invoke(agent, ctx, "write_note", "note-4", loop)

    bundle = runtime.check_current_capabilities(agent, ctx)
    assert "write_note" not in [t.name for t in bundle.tools]


def test_mcp_adapter_records_side_effects(tmp_path):
    runtime, adapter, loop = _adapter_and_loop(tmp_path)
    agent = AgentIdentity("agent-mcp-3")

    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-write-note"), "Side effect test"
    )

    adapter.invoke(agent, {}, "write_note", "hello world", loop)

    assert adapter.side_effects == ["write_note:hello world"]


def test_register_mcp_tool_respects_initial_state(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-mcp-4", 201)
    adapter = McpToolAdapter(runtime)
    ref = CapabilityRef("cap-visible-note")

    adapter.register_mcp_tool(
        McpToolCapability(name="visible_note", ref=ref, description="Always visible"),
        initial_state=LifecycleState.VISIBLE,
    )

    agent = AgentIdentity("agent-mcp-4")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "visible_note" in [t.name for t in bundle.tools]
