from pathlib import Path
import json
from capability_runtime.daemon import load_catalog_into_runtime
from capability_runtime.netbird_client import MockNetBirdClient
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_network_lease_uses_catalog_quota(tmp_path):
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({
        "capabilities": [{
            "name": "reach_proxy",
            "ref": "cap-reach-proxy",
            "type": "network",
            "peer_id": "peer-pp",
            "network": "100.64.0.5/32",
            "sync_mode": "route_enable",
            "lease_policy": {"quota": 5, "ttl_minutes": 15, "token_budget": 10000},
        }]
    }))
    client = MockNetBirdClient(peers=[{"id": "peer-pp"}], routes=[])
    runtime = CapabilityRuntime(tmp_path / "t.jsonl", "trace", 1, netbird_client=client)
    load_catalog_into_runtime(runtime, catalog)
    agent = AgentIdentity("agent-1")
    decision = runtime.request_capability_lease(agent, agent, CapabilityRef("cap-reach-proxy"), "gate")
    assert decision.quota == 5
