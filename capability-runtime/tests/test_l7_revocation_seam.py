"""Test L7 revocation push integration in CapabilityRuntime (primary seam)."""

def test_logical_revoke_pushes_l7_with_catalog_policy(tmp_path):
    """Test that revoke_capability pushes L7 with catalog policy."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, RevocationClosePolicy
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    # Setup fake unix socket peer to capture L7 push requests (reuse Task 5 pattern)
    socket_path = tmp_path / "fake_revoke.sock"
    
    import socket
    import threading
    import json
    import time
    
    box = {}  # shared state to capture request
    
    def _serve_one(sock_path, box):
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(sock_path))
        srv.listen(1)
        srv.settimeout(2)
        conn, _ = srv.accept()
        with conn:
            data = b""
            while b"\n" not in data:
                data += conn.recv(4096)
            req = json.loads(data.split(b"\n", 1)[0])
            box["req"] = req
            conn.sendall(b'{"jsonrpc":"2.0","id":1,"result":{"revoked":true}}\n')
        srv.close()
    
    # Start fake peer in background
    peer_thread = threading.Thread(target=_serve_one, args=(socket_path, box), daemon=True)
    peer_thread.start()
    
    # Wait for socket to be available
    for _ in range(50):
        if socket_path.exists():
            break
        time.sleep(0.01)
    
    # Create runtime with fake socket and netbird client
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(
        trace_file=tmp_path / "trace.jsonl",
        trace_id="test-trace",
        seed=42,
        netbird_client=client,
        l7_revoke_socket=socket_path,
    )
    
    # Register network capability with drain policy
    operator = AgentIdentity("operator")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="peer-abc",
        network="10.8.0.0/24", 
        route_id="route-1",
        revoke_close_policy=RevocationClosePolicy.DRAIN,
        revoke_drain_seconds=30,
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    
    # Revoke capability - should push L7 with catalog drain policy
    runtime.revoke_capability(operator, ref, "stop")
    
    # Wait for peer thread to complete
    peer_thread.join(timeout=2)
    
    # Verify L7 push was made with correct parameters
    assert "req" in box, f"No request received, box: {box}"
    req = box["req"]
    assert req["method"] == "mitmproxy.l7.revoke_flows"
    assert req["params"]["host_patterns"] == ["10.8.0.0/24"]
    assert req["params"]["close_policy"] == "drain"
    assert req["params"]["drain_seconds"] == 30
    assert req["params"]["capability_ref"] == "cap-reach-api"
    assert req["params"]["reason"] == "stop"
    assert req["params"]["trigger"] == "operator"
    
    # Verify NetBird disable was still called
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    
    # Verify observability event was emitted  
    events = runtime.observability._events
    l7_push_events = [e for e in events if e.get("event") == "l7_revoke_push"]
    assert len(l7_push_events) == 1
    event = l7_push_events[0]
    assert event["capability_ref"] == "cap-reach-api"
    assert event["close_policy"] == "drain"
    assert event["host_patterns"] == ["10.8.0.0/24"]


def test_cli_immediate_overrides_catalog_drain(tmp_path):
    """Test that CLI close_policy=IMMEDIATE overrides catalog drain."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, RevocationClosePolicy
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    # Setup fake unix socket peer (reuse Task 5 pattern)
    socket_path = tmp_path / "fake_revoke.sock"
    
    import socket
    import threading
    import json
    import time
    
    box = {}
    
    def _serve_one(sock_path, box):
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(sock_path))
        srv.listen(1)
        srv.settimeout(2)
        conn, _ = srv.accept()
        with conn:
            data = b""
            while b"\n" not in data:
                data += conn.recv(4096)
            req = json.loads(data.split(b"\n", 1)[0])
            box["req"] = req
            conn.sendall(b'{"jsonrpc":"2.0","id":1,"result":{"revoked":true}}\n')
        srv.close()
    
    peer_thread = threading.Thread(target=_serve_one, args=(socket_path, box), daemon=True)
    peer_thread.start()
    
    # Wait for socket to be available
    for _ in range(50):
        if socket_path.exists():
            break
        time.sleep(0.01)
    
    # Create runtime 
    client = MockNetBirdClient()
    runtime = CapabilityRuntime(
        trace_file=tmp_path / "trace.jsonl",
        trace_id="test-trace",
        seed=42,
        netbird_client=client,
        l7_revoke_socket=socket_path,
    )
    
    # Register capability with DRAIN policy in catalog
    operator = AgentIdentity("operator") 
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id="route-1", 
        revoke_close_policy=RevocationClosePolicy.DRAIN,
        revoke_drain_seconds=60,
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    
    # Revoke with CLI override to IMMEDIATE
    runtime.revoke_capability(
        operator, ref, "emergency", 
        close_policy=RevocationClosePolicy.IMMEDIATE
    )
    
    # Wait for peer thread to complete
    peer_thread.join(timeout=2)
    
    # Verify L7 push used IMMEDIATE, not catalog DRAIN
    assert "req" in box
    req = box["req"]
    assert req["params"]["close_policy"] == "immediate"
    assert req["params"]["drain_seconds"] is None  # No drain for immediate


def test_push_failure_still_physically_revokes(tmp_path):
    """Test that L7 push failure doesn't prevent physical revocation."""
    from capability_runtime.catalog import LifecycleState
    from capability_runtime.netbird_client import MockNetBirdClient
    from capability_runtime.network import NetworkBinding, RevocationClosePolicy
    from capability_runtime.runtime import CapabilityRuntime
    from capability_runtime.types import AgentIdentity, CapabilityRef

    # No socket file - push will fail
    missing_socket = tmp_path / "missing.sock"
    
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24", "enabled": True}],
    )
    runtime = CapabilityRuntime(
        trace_file=tmp_path / "trace.jsonl",
        trace_id="test-trace", 
        seed=42,
        netbird_client=client,
        l7_revoke_socket=missing_socket,  # This will cause push to fail
    )
    
    # Register network capability
    operator = AgentIdentity("operator")
    ref = CapabilityRef("cap-reach-api")
    binding = NetworkBinding(
        capability_ref=ref,
        peer_id="peer-abc", 
        network="10.8.0.0/24",
        route_id="route-1",
    )
    runtime.register_network_capability("reach_api", ref, binding, LifecycleState.VISIBLE)
    
    # Revoke - L7 push will fail but physical should still work
    runtime.revoke_capability(operator, ref, "stop")
    
    # Verify NetBird disable was still called despite L7 push failure
    routes = [r for r in client.list_routes() if r["id"] == "route-1"]
    assert routes[0]["enabled"] is False
    
    # Verify l7_revoke_push_failed event was emitted
    events = runtime.observability._events
    failed_events = [e for e in events if e.get("event") == "l7_revoke_push_failed"]
    assert len(failed_events) == 1
    
    # Verify physical_revocation is still True in main revoke event
    revoke_events = [e for e in events if e.get("event") == "capability_revoked"]
    assert len(revoke_events) == 1
    assert revoke_events[0]["physical_revocation"] is True