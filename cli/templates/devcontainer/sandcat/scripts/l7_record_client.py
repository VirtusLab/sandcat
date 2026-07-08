"""Best-effort post-hoc flow record to capability-runtime admin socket."""
import json
import os
import socket

ADMIN_SOCKET = os.environ.get(
    "CAPABILITY_ADMIN_SOCKET", "/run/sandcat-capability/admin.sock"
)

def record_flow(*, agent_id: str, host: str, method: str, status: int) -> None:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "capability.l7.record",
        "params": {
            "agent_id": agent_id,
            "host": host,
            "method": method,
            "status": status,
        },
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.2)
            sock.connect(ADMIN_SOCKET)
            sock.sendall((json.dumps(payload) + "\n").encode())
    except OSError:
        return  # best-effort; never block mitmproxy
