"""Integration tests for grant → enable_binding → revoke flow."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


@pytest.fixture
def temp_trace_file(tmp_path: Path) -> Path:
    """Create a temporary trace file."""
    return tmp_path / "trace.jsonl"


@pytest.fixture
def netbird_client() -> MockNetBirdClient:
    """Create a mock NetBird client."""
    return MockNetBirdClient(
        peers=[{"id": "peer-123", "name": "test-peer"}],
        routes=[],
    )


@pytest.fixture
def runtime_with_netbird(temp_trace_file: Path, netbird_client: MockNetBirdClient) -> CapabilityRuntime:
    """Create a runtime with NetBird backend enabled."""
    return CapabilityRuntime(
        trace_file=temp_trace_file,
        trace_id="test-trace",
        seed=42,
        netbird_client=netbird_client,
    )


def test_grant_network_capability_enables_binding(
    runtime_with_netbird: CapabilityRuntime,
    netbird_client: MockNetBirdClient,
) -> None:
    """Test that granting a network capability calls enable_binding and emits capability_leased."""
    # Register a network capability in VISIBLE state
    ref = CapabilityRef("cap-network-test")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="peer-123",
        network="10.0.0.0/24",
        route_id=None,  # No route yet
        sync_mode=SyncMode.ROUTE_ENABLE,
    )
    runtime_with_netbird.register_network_capability(
        "network_test",
        ref,
        binding,
        initial_state=LifecycleState.VISIBLE,
    )

    # Grant lease
    agent_id = AgentIdentity("test-agent")
    decision = runtime_with_netbird.request_capability_lease(
        caller=agent_id,
        agent_id=agent_id,
        capability_ref=ref,
        justification="testing network grant",
    )

    # Verify lease granted
    assert decision.lease_id is not None

    # Verify binding was enabled (route created)
    routes = netbird_client.list_routes()
    assert len(routes) == 1
    assert routes[0]["network"] == "10.0.0.0/24"
    assert routes[0]["peer"] == "peer-123"
    assert routes[0]["enabled"] is True

    # Verify route_id was persisted in catalog
    updated_binding = runtime_with_netbird.catalog.get_network_binding(ref)
    assert updated_binding is not None
    assert updated_binding.route_id is not None
    assert updated_binding.route_id == routes[0]["id"]

    # Verify capability_leased event was emitted with physical_sync metadata
    events = runtime_with_netbird.observability._events
    leased_events = [e for e in events if e.get("event") == "capability_leased"]
    assert len(leased_events) >= 1
    last_leased = leased_events[-1]
    assert last_leased.get("physical_sync") == "enabled"
    assert last_leased.get("capability_ref") == ref.value


def test_grant_network_capability_rolls_back_on_enable_failure(
    runtime_with_netbird: CapabilityRuntime,
    netbird_client: MockNetBirdClient,
) -> None:
    """Test that enable_binding failure rolls back the lease grant (fail closed)."""
    # Register a network capability
    ref = CapabilityRef("cap-network-fail")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="nonexistent-peer",  # This will cause enable_binding to fail
        network="10.0.0.0/24",
        route_id=None,
        sync_mode=SyncMode.ROUTE_ENABLE,
    )
    runtime_with_netbird.register_network_capability(
        "network_fail",
        ref,
        binding,
        initial_state=LifecycleState.VISIBLE,
    )

    # Mock enable_binding to raise an error
    original_enable = netbird_client.enable_binding

    def failing_enable(binding: NetworkBinding) -> NetworkBinding:
        raise RuntimeError("NetBird API failure")

    netbird_client.enable_binding = failing_enable  # type: ignore

    # Attempt to grant lease should fail
    agent_id = AgentIdentity("test-agent")
    with pytest.raises(RuntimeError, match="NetBird API failure"):
        runtime_with_netbird.request_capability_lease(
            caller=agent_id,
            agent_id=agent_id,
            capability_ref=ref,
            justification="testing rollback",
        )

    # Verify lease was NOT granted (rolled back)
    assert len(runtime_with_netbird.lease_manager._leases) == 0

    # Verify catalog state was rolled back (should be VISIBLE, not LEASED)
    state = runtime_with_netbird.catalog.get_state(ref)
    assert state == LifecycleState.VISIBLE

    # Restore original function
    netbird_client.enable_binding = original_enable  # type: ignore


def test_grant_tool_capability_skips_physical_sync(
    runtime_with_netbird: CapabilityRuntime,
    netbird_client: MockNetBirdClient,
) -> None:
    """Test that granting a non-network (tool) capability does not call enable_binding."""
    # Use the built-in create_pr capability (registered in __init__)
    ref = CapabilityRef("cap-create-pr")
    runtime_with_netbird.catalog.set_state(ref, LifecycleState.VISIBLE)

    # Grant lease
    agent_id = AgentIdentity("test-agent")
    decision = runtime_with_netbird.request_capability_lease(
        caller=agent_id,
        agent_id=agent_id,
        capability_ref=ref,
        justification="testing tool grant",
    )

    # Verify lease granted
    assert decision.lease_id is not None

    # Verify no routes were created (no physical sync for tool capabilities)
    routes = netbird_client.list_routes()
    assert len(routes) == 0

    # Verify lease_granted event was emitted (not capability_leased with physical_sync)
    events = runtime_with_netbird.observability._events
    granted_events = [e for e in events if e.get("event") == "lease_granted"]
    assert len(granted_events) >= 1


def test_grant_network_capability_with_existing_route(
    runtime_with_netbird: CapabilityRuntime,
    netbird_client: MockNetBirdClient,
) -> None:
    """Test that granting a network capability with an existing route_id enables it."""
    # Pre-create a disabled route
    netbird_client._routes.append(
        {
            "id": "route-existing",
            "network": "10.0.0.0/24",
            "peer": "peer-123",
            "enabled": False,
        }
    )

    # Register a network capability with existing route_id
    ref = CapabilityRef("cap-network-existing")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="peer-123",
        network="10.0.0.0/24",
        route_id="route-existing",  # Existing route
        sync_mode=SyncMode.ROUTE_ENABLE,
    )
    runtime_with_netbird.register_network_capability(
        "network_existing",
        ref,
        binding,
        initial_state=LifecycleState.VISIBLE,
    )

    # Grant lease
    agent_id = AgentIdentity("test-agent")
    decision = runtime_with_netbird.request_capability_lease(
        caller=agent_id,
        agent_id=agent_id,
        capability_ref=ref,
        justification="testing existing route",
    )

    # Verify lease granted
    assert decision.lease_id is not None

    # Verify existing route was enabled (not a new route created)
    routes = netbird_client.list_routes()
    assert len(routes) == 1
    assert routes[0]["id"] == "route-existing"
    assert routes[0]["enabled"] is True

    # Verify capability_leased event
    events = runtime_with_netbird.observability._events
    leased_events = [e for e in events if e.get("event") == "capability_leased"]
    assert len(leased_events) >= 1
    last_leased = leased_events[-1]
    assert last_leased.get("physical_sync") == "enabled"
