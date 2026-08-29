"""Integration tests for CapabilityRuntime (spec §3.2 and §5.1)."""

from datetime import datetime, timezone

import pytest
from lease_support import register_test_policy

from capability_runtime.catalog import LifecycleState
from capability_runtime.errors import BundleVersionMismatch, CapabilityNotVisible
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef
from capability_runtime.discover import DiscoveryIntent

_OPERATOR = AgentIdentity("operator")


def test_poc1_create_pr_lifecycle(tmp_path):
    """Full PoC 1: create_pr invisible → lease → visible → use → gone"""
    register_test_policy("create_pr")
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-1", 42)
    agent = AgentIdentity("agent-1")
    ctx = {}

    # Step 1: not present
    bundle1 = runtime.check_current_capabilities(agent, ctx)
    tool_names = [t.name for t in bundle1.tools]
    assert "create_pr" not in tool_names

    # Step 2: request lease
    decision = runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "Need to open PR for feature"
    )
    assert decision.quota == 1

    # Step 3: present with lease
    bundle2 = runtime.check_current_capabilities(agent, ctx)
    create_pr_tools = [t for t in bundle2.tools if t.name == "create_pr"]
    assert len(create_pr_tools) == 1
    assert create_pr_tools[0].lease_id is not None

    # Step 4: use (record action)
    now = datetime.now(timezone.utc)
    runtime.record_action(agent, agent, create_pr_tools[0].lease_id, now)

    # Step 5: gone after quota exhausted
    bundle3 = runtime.check_current_capabilities(agent, ctx)
    assert "create_pr" not in [t.name for t in bundle3.tools]


def test_revoke_by_lease_id(tmp_path):
    """Test revoking a capability by lease ID"""
    register_test_policy("create_pr")
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-2", 43)
    agent = AgentIdentity("agent-2")

    # Request lease
    decision = runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "Testing revoke"
    )

    # Verify present
    bundle1 = runtime.check_current_capabilities(agent, {})
    assert "create_pr" in [t.name for t in bundle1.tools]

    # Revoke by lease ID
    runtime.revoke_capability(_OPERATOR, decision.lease_id, "policy violation")

    # Verify gone
    bundle2 = runtime.check_current_capabilities(agent, {})
    assert "create_pr" not in [t.name for t in bundle2.tools]


def test_revoke_by_capability_ref(tmp_path):
    """Test revoking a capability by reference"""
    register_test_policy("create_pr")
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-3", 44)
    agent = AgentIdentity("agent-3")

    # Request lease
    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "Testing revoke"
    )

    # Verify present
    bundle1 = runtime.check_current_capabilities(agent, {})
    assert "create_pr" in [t.name for t in bundle1.tools]

    # Revoke by ref
    runtime.revoke_capability(
        _OPERATOR, CapabilityRef("cap-create-pr"), "security concern"
    )

    # Verify gone
    bundle2 = runtime.check_current_capabilities(agent, {})
    assert "create_pr" not in [t.name for t in bundle2.tools]


def test_discover_capabilities(tmp_path):
    """Test capability discovery"""
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-4", 45)
    agent = AgentIdentity("agent-4")

    # Register a discoverable capability
    runtime.catalog.register(
        "merge_pr", CapabilityRef("cap-merge-pr"), LifecycleState.DISCOVERABLE
    )

    # Discover by query
    result = runtime.discover_capabilities(agent, DiscoveryIntent("merge"))
    assert len(result.capabilities) == 1
    assert result.capabilities[0]["name"] == "merge_pr"
    assert not result.denied

    # Query that doesn't match
    result2 = runtime.discover_capabilities(agent, DiscoveryIntent("deploy"))
    assert len(result2.capabilities) == 0
    assert result2.denied


def test_bundle_version_mismatch(tmp_path):
    """Test enforce_action raises BundleVersionMismatch for stale version"""
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-5", 46)
    agent = AgentIdentity("agent-5")

    # Get initial bundle
    bundle1 = runtime.check_current_capabilities(agent, {})

    # Get another bundle (increments version)
    bundle2 = runtime.check_current_capabilities(agent, {})

    # Try to enforce action with old bundle version
    now = datetime.now(timezone.utc)
    with pytest.raises(BundleVersionMismatch) as exc_info:
        runtime.enforce_action(agent, "create_pr", bundle1.version, now)

    assert exc_info.value.expected == bundle2.version
    assert exc_info.value.actual == bundle1.version


def test_enforce_action_not_visible(tmp_path):
    """Test enforce_action raises CapabilityNotVisible for tool not in bundle"""
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-6", 47)
    agent = AgentIdentity("agent-6")

    # Get bundle (create_pr is DECLARED, not visible)
    bundle = runtime.check_current_capabilities(agent, {})

    # Try to enforce action on invisible capability
    now = datetime.now(timezone.utc)
    with pytest.raises(CapabilityNotVisible):
        runtime.enforce_action(agent, "create_pr", bundle.version, now)
