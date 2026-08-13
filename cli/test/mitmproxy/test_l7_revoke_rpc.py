import json
import socket
import time
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parents[2] / "templates/devcontainer/sandcat/scripts"
sys.path.insert(0, str(SCRIPTS))

from l7_revoke_rpc import (
    FlowTracker,
    RevokeRpcServer,
    RevokeState,
    apply_close_to_flows,
    handle_restore_flows,
    host_matches_revoke_pattern,
)


def _rpc_call(sock_path: Path, request: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2)
        s.connect(str(sock_path))
        s.sendall((json.dumps(request) + "\n").encode())
        line = s.recv(65536)
    assert line.endswith(b"\n")
    return json.loads(line.decode().strip())


def test_host_matches_cidr():
    assert host_matches_revoke_pattern("10.8.0.5", "10.8.0.0/24") is True
    assert host_matches_revoke_pattern("10.9.0.5", "10.8.0.0/24") is False


def test_host_matches_dns_label_exact():
    assert host_matches_revoke_pattern(
        "test-proxy-peer.netbird.selfhosted", "test-proxy-peer.netbird.selfhosted"
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


def test_apply_close_to_flows_drain_deadline_kills_every_matching_flow():
    """Each flow needs its own timer binding, not a shared closure variable."""
    flows = [MockFlow("api.example.com") for _ in range(3)]

    apply_close_to_flows(
        flows=flows,
        host_patterns=["api.example.com"],
        close_policy="drain_deadline",
        drain_seconds=0.1,
    )

    time.sleep(0.3)

    assert [flow.killed for flow in flows] == [True, True, True]


def test_apply_close_to_flows_immediate_continues_past_a_failing_kill():
    """One flow that refuses to die must not spare the rest of the matches."""
    exploding = MockFlow("api.example.com")
    exploding.kill = lambda: (_ for _ in ()).throw(RuntimeError("already closed"))
    survivor = MockFlow("api.example.com")

    apply_close_to_flows(
        flows=[exploding, survivor],
        host_patterns=["api.example.com"],
        close_policy="immediate",
        drain_seconds=None,
    )

    assert survivor.killed is True


def test_drain_deadline_timer_skips_a_flow_whose_flag_was_cleared():
    """The addon clears the flag when it drains a flow; the timer must respect that."""
    flow = MockFlow("api.example.com")

    apply_close_to_flows(
        flows=[flow],
        host_patterns=["api.example.com"],
        close_policy="drain_deadline",
        drain_seconds=0.1,
    )
    flow.metadata.pop("sandcat_l7_drain")

    time.sleep(0.3)

    assert flow.killed is False


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
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        resp = _rpc_call(
            sock_path,
            {
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
            },
        )
        assert "result" in resp
        assert resp["result"]["revoked"] is True
        assert state.is_host_revoked("10.8.0.1") is True
    finally:
        server.stop()


def test_revoke_flows_rpc_closes_tracked_flows(tmp_path):
    """The server closes flows the addon is tracking, not a stubbed list."""
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    tracker = FlowTracker()
    doomed = MockFlow("api.example.com")
    spared = MockFlow("other.example.com")
    tracker.register(doomed)
    tracker.register(spared)

    server = RevokeRpcServer(sock_path, state, get_active_flows=tracker.active)
    server.start()
    assert server.wait_ready(2) is True
    try:
        resp = _rpc_call(
            sock_path,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "mitmproxy.l7.revoke_flows",
                "params": {
                    "host_patterns": ["api.example.com"],
                    "close_policy": "immediate",
                    "capability_ref": "cap-reach-api",
                },
            },
        )
        assert resp["result"]["revoked"] is True
        assert doomed.killed is True
        assert spared.killed is False
    finally:
        server.stop()


def test_restore_flows_rpc_clears_revocation(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        _rpc_call(
            sock_path,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "mitmproxy.l7.revoke_flows",
                "params": {
                    "host_patterns": ["10.8.0.0/24"],
                    "close_policy": "deny_new",
                    "capability_ref": "cap-reach-api",
                },
            },
        )
        assert state.is_host_revoked("10.8.0.1") is True

        resp = _rpc_call(
            sock_path,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "mitmproxy.l7.restore_flows",
                "params": {
                    "host_patterns": ["10.8.0.0/24"],
                    "capability_ref": "cap-reach-api",
                    "reason": "lease granted",
                    "trigger": "lease_granted",
                },
            },
        )
        assert resp["result"]["restored"] is True
        assert resp["result"]["cleared"] >= 1
        assert state.is_host_revoked("10.8.0.1") is False
    finally:
        server.stop()


def test_revoke_flows_rpc_unknown_method(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        resp = _rpc_call(
            sock_path,
            {"jsonrpc": "2.0", "id": 1, "method": "unknown.method", "params": {}},
        )
        assert "error" in resp
        assert resp["error"]["code"] == -32601  # Method not found
    finally:
        server.stop()


def test_revoke_flows_rpc_missing_host_patterns(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        resp = _rpc_call(
            sock_path,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "mitmproxy.l7.revoke_flows",
                "params": {"close_policy": "immediate"},  # missing host_patterns
            },
        )
        assert "error" in resp
        assert resp["error"]["code"] == -32602  # Invalid params
    finally:
        server.stop()


def test_restore_flows_rpc_requires_a_target(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        resp = _rpc_call(
            sock_path,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "mitmproxy.l7.restore_flows",
                "params": {"reason": "lease granted"},
            },
        )
        assert "error" in resp
        assert resp["error"]["code"] == -32602  # Invalid params
    finally:
        server.stop()


def test_revoke_flows_rpc_invalid_json(tmp_path):
    sock_path = tmp_path / "l7-revoke.sock"
    state = RevokeState()
    server = RevokeRpcServer(sock_path, state, get_active_flows=lambda: [])
    server.start()
    assert server.wait_ready(2) is True
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(str(sock_path))
            s.sendall(b"not json\n")
            line = s.recv(65536)
        resp = json.loads(line.decode().strip())
        assert line.endswith(b"\n")
        assert "error" in resp
        assert resp["error"]["code"] == -32700  # Parse error
    finally:
        server.stop()


# ---------------------------------------------------------------------------
# Restore (un-revoke) state transitions
# ---------------------------------------------------------------------------


def test_clear_patterns_only_drops_named_patterns():
    state = RevokeState()
    state.apply_revoke(
        host_patterns=["10.8.0.0/24", "api.example.com"],
        close_policy="deny_new",
        drain_seconds=None,
        capability_ref="cap-reach-api",
    )

    assert state.clear_patterns(["api.example.com"]) == 1
    assert state.is_host_revoked("api.example.com") is False
    assert state.is_host_revoked("10.8.0.5") is True


def test_clear_patterns_scoped_to_capability_spares_other_capabilities():
    state = RevokeState()
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-a")
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-b")

    assert state.clear_patterns(["10.8.0.0/24"], capability_ref="cap-a") == 1
    assert state.is_host_revoked("10.8.0.5") is True

    assert state.clear_patterns(["10.8.0.0/24"], capability_ref="cap-b") == 1
    assert state.is_host_revoked("10.8.0.5") is False


def test_restore_flows_scoped_to_capability_leaves_shared_cidr_revoked():
    """Restoring cap-a must not lift cap-b's revoke of the same CIDR."""
    state = RevokeState()
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-a")
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-b")

    result = handle_restore_flows(
        state,
        {"host_patterns": ["10.8.0.0/24"], "capability_ref": "cap-a"},
    )

    assert result["restored"] is True
    assert state.is_host_revoked("10.8.0.5") is True
    assert [entry.capability_ref for entry in state.entries] == ["cap-b"]


def test_clear_patterns_without_capability_ref_clears_every_entry():
    state = RevokeState()
    state.apply_revoke(["api.example.com"], "deny_new", None, "cap-a")
    state.apply_revoke(["api.example.com"], "deny_new", None, "cap-b")

    assert state.clear_patterns(["api.example.com"]) == 2
    assert state.is_host_revoked("api.example.com") is False


def test_clear_patterns_matches_literally_not_by_cidr_containment():
    state = RevokeState()
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-reach-api")

    assert state.clear_patterns(["10.8.0.5"]) == 0
    assert state.is_host_revoked("10.8.0.5") is True


def test_clear_capability_drops_every_entry_for_that_ref():
    state = RevokeState()
    state.apply_revoke(["10.8.0.0/24"], "deny_new", None, "cap-reach-api")
    state.apply_revoke(["peer.netbird.selfhosted"], "drain", None, "cap-reach-api")
    state.apply_revoke(["other.example.com"], "deny_new", None, "cap-other")

    assert state.clear_capability("cap-reach-api") == 2
    assert state.is_host_revoked("10.8.0.5") is False
    assert state.is_host_revoked("peer.netbird.selfhosted") is False
    assert state.is_host_revoked("other.example.com") is True


def test_restore_after_revoke_reallows_host():
    state = RevokeState()
    state.apply_revoke(["api.example.com"], "deny_new", None, "cap-reach-api")
    assert state.is_host_revoked("api.example.com") is True

    result = handle_restore_flows(state, {"capability_ref": "cap-reach-api"})

    assert result["restored"] is True
    assert result["cleared"] == 1
    assert state.is_host_revoked("api.example.com") is False


# ---------------------------------------------------------------------------
# Flow tracking
# ---------------------------------------------------------------------------


def test_flow_tracker_registers_and_unregisters():
    tracker = FlowTracker()
    flow = MockFlow("api.example.com")

    tracker.register(flow)
    assert tracker.active() == [flow]

    tracker.unregister(flow)
    assert tracker.active() == []


def test_flow_tracker_deduplicates_by_flow_id():
    tracker = FlowTracker()
    flow = MockFlow("api.example.com")
    flow.id = "flow-1"

    tracker.register(flow)
    tracker.register(flow)

    assert len(tracker) == 1


def test_flow_tracker_unregister_is_idempotent():
    tracker = FlowTracker()
    flow = MockFlow("api.example.com")

    tracker.unregister(flow)
    tracker.register(flow)
    tracker.unregister(flow)
    tracker.unregister(flow)

    assert tracker.active() == []