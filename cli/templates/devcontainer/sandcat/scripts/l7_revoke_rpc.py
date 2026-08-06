from __future__ import annotations

import ipaddress
import json
import os
import socket
import threading
from dataclasses import dataclass, field
from fnmatch import fnmatch
from pathlib import Path
from typing import Callable, Protocol


def host_matches_revoke_pattern(host: str, pattern: str) -> bool:
    host = host.lower().rstrip(".")
    pattern_l = pattern.lower().rstrip(".")
    try:
        net = ipaddress.ip_network(pattern, strict=False)
    except ValueError:
        return host == pattern_l or fnmatch(host, pattern_l)
    try:
        return ipaddress.ip_address(host) in net
    except ValueError:
        return False


@dataclass
class RevokeEntry:
    host_patterns: list[str]
    close_policy: str
    drain_seconds: int | None


@dataclass
class RevokeState:
    entries: list[RevokeEntry] = field(default_factory=list)

    def apply_revoke(
        self,
        host_patterns: list[str],
        close_policy: str,
        drain_seconds: int | None,
    ) -> None:
        self.entries.append(
            RevokeEntry(list(host_patterns), close_policy, drain_seconds)
        )

    def is_host_revoked(self, host: str) -> bool:
        return any(
            host_matches_revoke_pattern(host, p)
            for entry in self.entries
            for p in entry.host_patterns
        )


class FlowLike(Protocol):
    """Protocol for flow-like objects used in close policy application"""
    
    @property
    def pretty_host(self) -> str:
        ...
    
    def kill(self) -> None:
        ...
    
    @property
    def metadata(self) -> dict:
        ...


def apply_close_to_flows(
    flows: list[FlowLike],
    host_patterns: list[str],
    close_policy: str,
    drain_seconds: int | None
) -> None:
    """Apply close policy to matching flows"""
    matching_flows = [
        flow for flow in flows
        if any(host_matches_revoke_pattern(flow.pretty_host, pattern) 
               for pattern in host_patterns)
    ]
    
    if close_policy == "immediate":
        for flow in matching_flows:
            flow.kill()
    elif close_policy in ("drain", "drain_deadline"):
        for flow in matching_flows:
            flow.metadata["sandcat_l7_drain"] = True
            if close_policy == "drain_deadline" and drain_seconds:
                # Start timer to kill if still open after deadline
                timer = threading.Timer(drain_seconds, lambda: _kill_if_still_open(flow))
                timer.start()
    # For "deny_new", no action needed on existing flows


def _kill_if_still_open(flow: FlowLike) -> None:
    """Helper to kill flow if it's still draining after deadline"""
    if flow.metadata.get("sandcat_l7_drain"):
        flow.kill()


def handle_revoke_flows(state: RevokeState, params: dict, get_active_flows: Callable) -> dict:
    """Handle the mitmproxy.l7.revoke_flows RPC method"""
    # Validate required parameters
    if "host_patterns" not in params:
        raise ValueError("Missing required parameter: host_patterns")
    if "close_policy" not in params:
        raise ValueError("Missing required parameter: close_policy")
    
    patterns = params["host_patterns"]
    policy = params["close_policy"]
    drain_seconds = params.get("drain_seconds")
    
    # Apply revocation to state
    state.apply_revoke(patterns, policy, drain_seconds)
    
    # Apply close policy to active flows
    apply_close_to_flows(get_active_flows(), patterns, policy, drain_seconds)
    
    return {"revoked": True, "host_patterns": patterns, "close_policy": policy}


class RevokeRpcServer:
    """Unix JSON-RPC server for mitmproxy.l7.revoke_flows method"""
    
    def __init__(self, socket_path: Path | str, state: RevokeState, get_active_flows: Callable):
        self.socket_path = Path(socket_path)
        self.state = state
        self.get_active_flows = get_active_flows
        self.server_socket = None
        self.running = False
        self.accept_thread = None
    
    def start(self):
        """Start the RPC server"""
        if self.running:
            return
        
        # Remove existing socket file if it exists
        if self.socket_path.exists():
            self.socket_path.unlink()
        
        # Create parent directory if needed
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Create and bind Unix socket
        self.server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_socket.bind(str(self.socket_path))
        
        # Set socket permissions to 0o600 (owner read/write only)
        os.chmod(str(self.socket_path), 0o600)
        
        self.server_socket.listen(5)
        self.running = True
        
        # Start accept thread
        self.accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.accept_thread.start()
    
    def stop(self):
        """Stop the RPC server"""
        if not self.running:
            return
        
        self.running = False
        
        if self.server_socket:
            self.server_socket.close()
        
        if self.accept_thread:
            self.accept_thread.join(timeout=1)
        
        # Clean up socket file
        if self.socket_path.exists():
            self.socket_path.unlink()
    
    def _accept_loop(self):
        """Accept incoming connections and handle them"""
        while self.running:
            try:
                client_socket, _ = self.server_socket.accept()
                # Handle each connection in a separate thread
                handler_thread = threading.Thread(
                    target=self._handle_client, 
                    args=(client_socket,), 
                    daemon=True
                )
                handler_thread.start()
            except OSError:
                # Socket closed, exit loop
                break
    
    def _handle_client(self, client_socket):
        """Handle a single client connection (one request per connection)"""
        try:
            # Read line-delimited JSON request
            data = b""
            while b"\n" not in data:
                chunk = client_socket.recv(4096)
                if not chunk:
                    return
                data += chunk
            
            # Parse the line up to first newline
            line = data.split(b"\n", 1)[0]
            request = json.loads(line.decode("utf-8"))
            
            # Handle the JSON-RPC request
            response = self._handle_jsonrpc_request(request)
            
            # Send response
            response_data = json.dumps(response).encode("utf-8")
            client_socket.sendall(response_data)
        
        except Exception as e:
            # Send error response
            error_response = {
                "jsonrpc": "2.0",
                "id": request.get("id") if "request" in locals() else None,
                "error": {
                    "code": -32603,  # Internal error
                    "message": str(e)
                }
            }
            try:
                response_data = json.dumps(error_response).encode("utf-8")
                client_socket.sendall(response_data)
            except:
                pass  # Client may have disconnected
        
        finally:
            client_socket.close()
    
    def _handle_jsonrpc_request(self, request: dict) -> dict:
        """Handle a JSON-RPC request and return response"""
        request_id = request.get("id")
        
        # Validate JSON-RPC structure
        if request.get("jsonrpc") != "2.0":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32600,  # Invalid Request
                    "message": "Invalid JSON-RPC version"
                }
            }
        
        method = request.get("method")
        if not method:
            return {
                "jsonrpc": "2.0", 
                "id": request_id,
                "error": {
                    "code": -32600,  # Invalid Request
                    "message": "Missing method"
                }
            }
        
        params = request.get("params", {})
        
        # Dispatch method
        if method == "mitmproxy.l7.revoke_flows":
            try:
                result = handle_revoke_flows(self.state, params, self.get_active_flows)
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": result
                }
            except ValueError as e:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,  # Invalid params
                        "message": str(e)
                    }
                }
        else:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32601,  # Method not found
                    "message": f"Method not found: {method}"
                }
            }