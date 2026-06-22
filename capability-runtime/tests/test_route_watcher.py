"""Tests for RouteDisappearanceWatcher (physical to logical revoke)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding
from capability_runtime.route_watcher import RouteDisappearanceWatcher
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_watcher_detects_removed_peer_and_revokes_runtime(tmp_path: Path):
    """Watcher detects peer removal and performs logical revoke."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl",
        "trace-w1",
        3,
        netbird_client=client,
    )

    # Register a network capability
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    # Verify capability is visible
    bundle_before = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle_before.networks]

    # Simulate external wg syncconf removing peer
    client.remove_peer("peer-abc")

    # Run watcher
    watcher = RouteDisappearanceWatcher(runtime, client)
    watcher.poll_once()

    # Verify capability is revoked
    bundle_after = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle_after.networks]


def test_watcher_handles_multiple_peers_selectively(tmp_path: Path):
    """Watcher only revokes capabilities for removed peers."""
    client = MockNetBirdClient(
        peers=[
            {"id": "peer-abc", "connected": True},
            {"id": "peer-def", "connected": True},
        ],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl",
        "trace-w2",
        4,
        netbird_client=client,
    )

    agent = AgentIdentity("agent-1")
    ref1 = CapabilityRef("cap-reach-api")
    ref2 = CapabilityRef("cap-reach-db")
    binding1 = NetworkBinding(ref1, "peer-abc", "10.8.0.0/24", None)
    binding2 = NetworkBinding(ref2, "peer-def", "10.8.1.0/24", None)
    
    runtime.register_network_capability("reach_api", ref1, binding1, LifecycleState.VISIBLE)
    runtime.register_network_capability("reach_db", ref2, binding2, LifecycleState.VISIBLE)

    # Remove only one peer
    client.remove_peer("peer-abc")

    watcher = RouteDisappearanceWatcher(runtime, client)
    watcher.poll_once()

    bundle = runtime.check_current_capabilities(agent, {})
    names = [n.name for n in bundle.networks]
    assert "reach_api" not in names
    assert "reach_db" in names


def test_watcher_emits_capability_event_with_physical_trigger(tmp_path: Path):
    """Watcher emits event with physical_trigger flag."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl",
        "trace-w3",
        5,
        netbird_client=client,
    )

    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    client.remove_peer("peer-abc")

    watcher = RouteDisappearanceWatcher(runtime, client)
    watcher.poll_once()

    # Read trace file to verify event
    trace_lines = (tmp_path / "t.jsonl").read_text().strip().split("\n")
    events = [json.loads(line) for line in trace_lines if line]
    
    revoke_events = [e for e in events if e.get("event") == "capability_revoked"]
    assert len(revoke_events) > 0
    assert any(e.get("physical_trigger") is True for e in revoke_events)


def test_watcher_does_nothing_when_all_peers_exist(tmp_path: Path):
    """Watcher is idempotent when no peers removed."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl",
        "trace-w4",
        6,
        netbird_client=client,
    )

    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    bundle_before = runtime.check_current_capabilities(agent, {})
    version_before = bundle_before.version

    watcher = RouteDisappearanceWatcher(runtime, client)
    watcher.poll_once()

    bundle_after = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle_after.networks]
    # Bundle version should have incremented due to check_current_capabilities calls
    assert bundle_after.version > version_before


def test_watcher_handles_empty_catalog(tmp_path: Path):
    """Watcher handles runtime with no network capabilities."""
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[],
    )
    runtime = CapabilityRuntime(
        tmp_path / "t.jsonl",
        "trace-w5",
        7,
        netbird_client=client,
    )

    watcher = RouteDisappearanceWatcher(runtime, client)
    # Should not raise
    watcher.poll_once()
