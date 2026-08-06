import ipaddress
import time
import threading
from pathlib import Path
from unittest.mock import MagicMock
import sys

SCRIPTS = Path(__file__).resolve().parents[2] / "templates/devcontainer/sandcat/scripts"
sys.path.insert(0, str(SCRIPTS))

from l7_revoke_rpc import RevokeState, host_matches_revoke_pattern, apply_close_to_flows


def test_host_matches_cidr():
    assert host_matches_revoke_pattern("10.8.0.5", "10.8.0.0/24") is True
    assert host_matches_revoke_pattern("10.9.0.5", "10.8.0.0/24") is False


def test_host_matches_dns_label_exact():
    assert host_matches_revoke_pattern(
        "peer-proxy.netbird.selfhosted", "peer-proxy.netbird.selfhosted"
    ) is True


def test_apply_revoke_marks_hosts_denied():
    state = RevokeState()
    state.apply_revoke(
        host_patterns=["10.8.0.0/24", "api.example.com"],
        close_policy="deny_new",
        drain_seconds=None,
    )
    assert state.is_host_revoked("10.8.0.5") is True
    assert state.is_host_revoked("api.example.com") is True
    assert state.is_host_revoked("other.com") is False


class MockFlow:
    """Mock flow-like object for testing close policies"""
    
    def __init__(self, pretty_host: str):
        self.pretty_host = pretty_host
        self.metadata = {}
        self.killed = False
    
    def kill(self):
        self.killed = True


def test_apply_close_to_flows_immediate():
    """Test immediate close policy kills matching flows"""
    matching_flow = MockFlow("api.example.com")
    non_matching_flow = MockFlow("other.example.com")
    flows = [matching_flow, non_matching_flow]
    
    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com"],
        close_policy="immediate",
        drain_seconds=None
    )
    
    # Matching flow should be killed
    assert matching_flow.killed is True
    # Non-matching flow should not be killed
    assert non_matching_flow.killed is False


def test_apply_close_to_flows_deny_new():
    """Test deny_new close policy does not kill any flows"""
    matching_flow = MockFlow("api.example.com")
    non_matching_flow = MockFlow("other.example.com")
    flows = [matching_flow, non_matching_flow]
    
    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com"],
        close_policy="deny_new",
        drain_seconds=None
    )
    
    # No flows should be killed
    assert matching_flow.killed is False
    assert non_matching_flow.killed is False
    # No drain metadata should be set
    assert "sandcat_l7_drain" not in matching_flow.metadata
    assert "sandcat_l7_drain" not in non_matching_flow.metadata


def test_apply_close_to_flows_drain():
    """Test drain close policy sets drain metadata on matching flows"""
    matching_flow = MockFlow("api.example.com")
    non_matching_flow = MockFlow("other.example.com")
    flows = [matching_flow, non_matching_flow]
    
    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com"],
        close_policy="drain",
        drain_seconds=None
    )
    
    # Matching flow should have drain metadata set
    assert matching_flow.metadata.get("sandcat_l7_drain") is True
    # Non-matching flow should not have drain metadata
    assert "sandcat_l7_drain" not in non_matching_flow.metadata
    # No flows should be immediately killed
    assert matching_flow.killed is False
    assert non_matching_flow.killed is False


def test_apply_close_to_flows_drain_deadline():
    """Test drain_deadline close policy sets drain metadata and starts timer"""
    matching_flow = MockFlow("api.example.com")
    non_matching_flow = MockFlow("other.example.com")
    flows = [matching_flow, non_matching_flow]
    
    # Use short drain_seconds for test
    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com"],
        close_policy="drain_deadline",
        drain_seconds=0.1  # 100ms
    )
    
    # Matching flow should have drain metadata set immediately
    assert matching_flow.metadata.get("sandcat_l7_drain") is True
    # Non-matching flow should not have drain metadata
    assert "sandcat_l7_drain" not in non_matching_flow.metadata
    # No flows should be immediately killed
    assert matching_flow.killed is False
    assert non_matching_flow.killed is False
    
    # Wait for timer to expire
    time.sleep(0.2)  # Wait longer than drain_seconds
    
    # Matching flow should now be killed by timer
    assert matching_flow.killed is True
    # Non-matching flow should still not be killed
    assert non_matching_flow.killed is False


def test_apply_close_to_flows_multiple_patterns():
    """Test apply_close_to_flows works with multiple host patterns"""
    flow1 = MockFlow("api.example.com")
    flow2 = MockFlow("test.example.org")
    flow3 = MockFlow("other.com")
    flows = [flow1, flow2, flow3]
    
    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com", "*.example.org"],
        close_policy="immediate",
        drain_seconds=None
    )
    
    # Both matching flows should be killed
    assert flow1.killed is True
    assert flow2.killed is True
    # Non-matching flow should not be killed
    assert flow3.killed is False


def test_apply_close_to_flows_cidr_pattern():
    """Test apply_close_to_flows works with CIDR patterns"""
    flow1 = MockFlow("10.8.0.5")
    flow2 = MockFlow("10.9.0.5") 
    flows = [flow1, flow2]
    
    apply_close_to_flows(
        flows=flows,
        host_patterns=["10.8.0.0/24"],
        close_policy="immediate",
        drain_seconds=None
    )
    
    # Only flow in CIDR range should be killed
    assert flow1.killed is True
    assert flow2.killed is False


def test_revoke_flows_rpc_updates_state(tmp_path):
    import json
    import socket
    import threading
    import time
    from pathlib import Path
    
    from l7_revoke_rpc import RevokeRpcServer
    
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    time.sleep(0.05)
    try:
        req = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "mitmproxy.l7.revoke_flows",
            "params": {
                "host_patterns": ["10.8.0.0/24"],
                "close_policy": "immediate",
                "drain_seconds": None,
                "capability_ref": "cap-reach-api",
                "reason": "test",
                "trigger": "operator",
            },
        }
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(str(sock_path))
            s.sendall((json.dumps(req) + "\n").encode())
            line = s.recv(65536)
        resp = json.loads(line)
        assert "result" in resp
        assert resp["result"]["revoked"] is True
        assert state.is_host_revoked("10.8.0.1") is True
    finally:
        server.stop()


def test_revoke_flows_rpc_unknown_method(tmp_path):
    import json
    import socket
    import time
    
    from l7_revoke_rpc import RevokeRpcServer
    
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    time.sleep(0.05)
    try:
        req = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "unknown.method",
            "params": {},
        }
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(str(sock_path))
            s.sendall((json.dumps(req) + "\n").encode())
            line = s.recv(65536)
        resp = json.loads(line)
        assert "error" in resp
        assert resp["error"]["code"] == -32601  # Method not found
    finally:
        server.stop()


def test_revoke_flows_rpc_missing_host_patterns(tmp_path):
    import json
    import socket
    import time
    
    from l7_revoke_rpc import RevokeRpcServer
    
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    time.sleep(0.05)
    try:
        req = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "mitmproxy.l7.revoke_flows",
            "params": {
                "close_policy": "immediate",
                # missing host_patterns
            },
        }
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(str(sock_path))
            s.sendall((json.dumps(req) + "\n").encode())
            line = s.recv(65536)
        resp = json.loads(line)
        assert "error" in resp
        assert resp["error"]["code"] == -32602  # Invalid params
    finally:
        server.stop()