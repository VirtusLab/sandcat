"""Integration tests for PoC 3 network route demo (spec Phase 3)."""

from __future__ import annotations

from pathlib import Path

from capability_runtime.types import CapabilityRef
from poc.network_route_demo import run_poc3_demo


def test_poc3_network_route_lifecycle(tmp_path: Path) -> None:
    """reach_api absent → lease → present → revoke → absent → external removal stays absent."""
    result = run_poc3_demo(tmp_path / "trace.jsonl", quiet=True)

    assert "reach_api" not in result.initial_networks
    assert result.lease_decision.capability_ref == CapabilityRef("cap-reach-api")
    assert "reach_api" in result.networks_after_lease
    assert result.peer_id_after_lease == "peer-abc"
    # Phase 3c: prefer disable over peer delete
    assert result.peer_still_exists_after_revoke is True
    assert result.route_disabled_by_revoke is True
    assert "reach_api" not in result.networks_after_revoke
    assert "reach_api" not in result.networks_after_external_removal
    assert result.external_removal_peer_gone is True


def test_poc3_demo_main_prints_steps(capsys, tmp_path: Path) -> None:
    """Runnable demo prints each step of the Phase 3 sequence."""
    from poc.network_route_demo import main

    main(trace_path=tmp_path / "trace.jsonl")

    out = capsys.readouterr().out
    assert "Step 1" in out
    assert "reach_api absent" in out.lower()
    assert "Step 2" in out
    assert "lease" in out.lower()
    assert "Step 3" in out
    assert "peer_id=" in out
    assert "Step 4" in out
    assert "revoke_capability" in out.lower()
    assert "Step 5" in out
    assert "Step 6" in out
    assert "watcher.poll_once" in out.lower() or "watcher" in out.lower()
