"""PoC 1 — create_pr leased capability demo (spec §5.1).

Runnable via:
  PYTHONPATH=src:. python poc/create_pr_demo.py
  PYTHONPATH=src:. python -m poc.create_pr_demo
"""

from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.errors import CapabilityNotVisible
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef, LeaseDecision


@dataclass
class DemoResult:
    initial_tools: list[str]
    lease_decision: LeaseDecision
    tools_after_lease: list[str]
    action_result: Any
    tools_after_use: list[str]
    retry_blocked: bool
    retry_error: CapabilityNotVisible | None
    adapted_action: str
    create_pr_retry_attempted: bool


def _tool_names(tools) -> list[str]:
    return [t.name for t in tools]


def _print_step(quiet: bool, step: int, message: str) -> None:
    if not quiet:
        print(f"Step {step}: {message}")


def run_poc1_demo(trace_path: Path, *, quiet: bool = False) -> DemoResult:
    """Execute the §5.1 create_pr lifecycle and optional adaptation step."""
    runtime = CapabilityRuntime(trace_path, "poc1-create-pr", seed=42)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("demo-agent")
    context: dict = {}

    bundle1 = runtime.check_current_capabilities(agent, context)
    initial_tools = _tool_names(bundle1.tools)
    _print_step(
        quiet,
        1,
        f"check_current_capabilities → tools={initial_tools} (create_pr absent)",
    )

    decision = runtime.request_capability_lease(
        agent,
        agent,
        CapabilityRef("cap-create-pr"),
        "Need to open PR for feature",
    )
    _print_step(
        quiet,
        2,
        f"request_capability_lease → LeaseDecision(lease_id={decision.lease_id.value!r}, "
        f"quota={decision.quota}, token_budget={decision.token_budget}, "
        f"risk_envelope={decision.risk_envelope!r})",
    )

    bundle2 = runtime.check_current_capabilities(agent, context)
    tools_after_lease = _tool_names(bundle2.tools)
    _print_step(
        quiet,
        3,
        f"check_current_capabilities → tools={tools_after_lease} (create_pr present)",
    )

    action_result = loop.run_step(
        agent,
        context,
        "create_pr",
        lambda: "PR created (mock)",
    )
    _print_step(
        quiet,
        4,
        f"AgentExecutionLoop.run_step(create_pr) → {action_result!r}",
    )

    bundle3 = runtime.check_current_capabilities(agent, context)
    tools_after_use = _tool_names(bundle3.tools)
    _print_step(
        quiet,
        5,
        f"check_current_capabilities → tools={tools_after_use} (create_pr absent)",
    )

    retry_error: CapabilityNotVisible | None = None
    retry_blocked = False
    try:
        loop.run_step(agent, context, "create_pr", lambda: "should not run")
    except CapabilityNotVisible as exc:
        retry_error = exc
        retry_blocked = True

    adapted_action = "draft_pr"
    create_pr_retry_attempted = False
    _print_step(
        quiet,
        6,
        "Agent adapts plan: using draft_pr instead",
    )

    return DemoResult(
        initial_tools=initial_tools,
        lease_decision=decision,
        tools_after_lease=tools_after_lease,
        action_result=action_result,
        tools_after_use=tools_after_use,
        retry_blocked=retry_blocked,
        retry_error=retry_error,
        adapted_action=adapted_action,
        create_pr_retry_attempted=create_pr_retry_attempted,
    )


def main(trace_path: Path | None = None) -> None:
    if trace_path is None:
        with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as handle:
            trace_path = Path(handle.name)
    run_poc1_demo(trace_path, quiet=False)


if __name__ == "__main__":
    main()
