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
