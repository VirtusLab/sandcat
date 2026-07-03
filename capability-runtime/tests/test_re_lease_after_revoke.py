# capability-runtime/tests/test_re_lease_after_revoke.py
from capability_runtime.catalog import LifecycleState
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef

_OPERATOR = AgentIdentity("operator")


def test_re_lease_after_revoke_by_ref(tmp_path):
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace-re", 2, netbird_client=client)
    agent = AgentIdentity("agent-1")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(ref, "peer-abc", "10.8.0.0/24", None, sync_mode=SyncMode.ROUTE_ENABLE)
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)

    runtime.request_capability_lease(agent, agent, ref, "first lease")
    runtime.revoke_capability(_OPERATOR, ref, "done")
    assert runtime.catalog.get_state(ref) == LifecycleState.REVOKED

    decision2 = runtime.request_capability_lease(agent, agent, ref, "second lease")
    assert decision2.lease_id is not None
    assert len(client.list_routes()) == 1
    bundle = runtime.check_current_capabilities(agent, {})
    assert "reach_api" in [n.name for n in bundle.networks]
