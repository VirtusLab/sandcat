#!/usr/bin/env python3
"""PoC 2: write_note MCP tool lifecycle (spec §5.2).

Same lifecycle as PoC 1 from the agent perspective:
  invisible → lease → visible → 3 invocations → gone
"""

from __future__ import annotations

import sys
from pathlib import Path

from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.mcp_adapter import McpToolAdapter, McpToolCapability
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def main() -> int:
    trace_file = Path("trace-mcp-tool-demo.jsonl")
    runtime = CapabilityRuntime(trace_file, "trace-mcp-demo-1", 42)
    adapter = McpToolAdapter(runtime)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("demo-agent")
    ctx: dict = {}

    adapter.register_mcp_tool(
        McpToolCapability(
            name="write_note",
            ref=CapabilityRef("cap-write-note"),
            description="Write a note to the workspace",
        )
    )

    # Step 1: not present
    bundle1 = runtime.check_current_capabilities(agent, ctx)
    tool_names = [t.name for t in bundle1.tools]
    print(f"Step 1 — initial bundle tools: {tool_names}")
    assert "write_note" not in tool_names

    # Step 2: request lease
    decision = runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-write-note"), "Need to record session notes"
    )
    print(
        f"Step 2 — lease granted: quota={decision.quota}, "
        f"token_budget={decision.token_budget}, risk={decision.risk_envelope}"
    )

    # Step 3: present with lease
    bundle2 = runtime.check_current_capabilities(agent, ctx)
    write_note_tools = [t for t in bundle2.tools if t.name == "write_note"]
    print(f"Step 3 — write_note in bundle: {len(write_note_tools) == 1}")
    assert len(write_note_tools) == 1

    # Step 4: use three times via MCP adapter
    for i in range(3):
        result = adapter.invoke(agent, ctx, "write_note", f"note-{i}", loop)
        print(f"Step 4.{i + 1} — invoke result: {result}")

    print(f"Step 4 — side effects recorded: {adapter.side_effects}")

    # Step 5: gone after quota exhausted
    bundle3 = runtime.check_current_capabilities(agent, ctx)
    tool_names_after = [t.name for t in bundle3.tools]
    print(f"Step 5 — final bundle tools: {tool_names_after}")
    assert "write_note" not in tool_names_after

    print("PoC 2 complete: write_note lifecycle verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
