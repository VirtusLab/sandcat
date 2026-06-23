"""Integration tests for PoC 1 create_pr demo (spec §5.1)."""

from __future__ import annotations

from pathlib import Path

import pytest

from capability_runtime.errors import CapabilityNotVisible
from capability_runtime.types import CapabilityRef
from poc.create_pr_demo import run_poc1_demo


def test_poc1_create_pr_lifecycle(tmp_path: Path) -> None:
    """create_pr absent → lease → present → use → absent."""
    result = run_poc1_demo(tmp_path / "trace.jsonl", quiet=True)

    assert "create_pr" not in result.initial_tools
    assert result.lease_decision.quota == 1
    assert result.lease_decision.capability_ref == CapabilityRef("cap-create-pr")
    assert "create_pr" in result.tools_after_lease
    assert result.action_result == "PR created (mock)"
    assert "create_pr" not in result.tools_after_use


def test_poc1_agent_adapts_instead_of_retrying_create_pr(tmp_path: Path) -> None:
    """After lease exhaustion, agent catches CapabilityNotVisible and uses draft_pr."""
    result = run_poc1_demo(tmp_path / "trace.jsonl", quiet=True)

    assert result.retry_blocked is True
    assert isinstance(result.retry_error, CapabilityNotVisible)
    assert result.adapted_action == "draft_pr"
    assert result.create_pr_retry_attempted is False


def test_poc1_demo_main_prints_steps(capsys, tmp_path: Path) -> None:
    """Runnable demo prints each step of the §5.1 sequence."""
    from poc.create_pr_demo import main

    main(trace_path=tmp_path / "trace.jsonl")

    out = capsys.readouterr().out
    assert "Step 1" in out
    assert "create_pr absent" in out.lower() or "create_pr not" in out.lower()
    assert "Step 2" in out
    assert "LeaseDecision" in out or "lease" in out.lower()
    assert "Step 3" in out
    assert "create_pr present" in out.lower() or "create_pr" in out
    assert "Step 4" in out
    assert "Step 5" in out
    assert "Agent adapts plan: using draft_pr instead" in out
