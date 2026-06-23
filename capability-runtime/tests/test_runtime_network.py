def test_register_network_capability_appears_in_bundle_when_visible(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient()
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n1", 1, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    bundle = runtime.check_current_capabilities(agent, {})
    assert any(n.name == "reach_api" for n in bundle.networks)
    cap = next(n for n in bundle.networks if n.name == "reach_api")
    assert cap.peer_id == "peer-abc"


def test_revoke_network_capability_calls_netbird_backend(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24"}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n2", 2, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", "route-1")
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    runtime.revoke_capability(ref, "security")
    assert not client.peer_exists("peer-abc")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" not in [n.name for n in bundle.networks]


def test_revoke_non_network_capability_does_not_call_netbird(tmp_path):
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    client = MockNetBirdClient(
        peers=[{"id": "peer-xyz", "connected": True}],
    )
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-n3", 3, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-create-pr")
    runtime.catalog.register("create_pr_tool", ref, LifecycleState.VISIBLE)
    runtime.revoke_capability(ref, "security")
    # Peer should still exist because we didn't revoke a network capability
    assert client.peer_exists("peer-xyz")
    bundle = runtime.check_current_capabilities(agent, {})
    assert "create_pr_tool" not in [t.name for t in bundle.tools]
