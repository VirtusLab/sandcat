from __future__ import annotations

import ipaddress
import json
import logging
import os
import socket
import threading
from dataclasses import dataclass, field
from fnmatch import fnmatch
from pathlib import Path
from typing import Callable, Protocol


def _normalize_pattern(pattern: str) -> str:
    return pattern.lower().rstrip(".")


def host_matches_revoke_pattern(host: str, pattern: str) -> bool:
    host = host.lower().rstrip(".")
    pattern_l = _normalize_pattern(pattern)
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
    capability_ref: str | None = None


@dataclass
class RevokeState:
    entries: list[RevokeEntry] = field(default_factory=list)
    _lock: threading.Lock = field(
        default_factory=threading.Lock, repr=False, compare=False
    )

    def apply_revoke(
        self,
        host_patterns: list[str],
        close_policy: str,
        drain_seconds: int | None,
        capability_ref: str | None = None,
    ) -> None:
        with self._lock:
            self.entries.append(
                RevokeEntry(
                    list(host_patterns), close_policy, drain_seconds, capability_ref
                )
            )

    def clear_patterns(self, host_patterns: list[str]) -> int:
        """Drop the given patterns from every entry; returns entries touched.

        Patterns are matched literally (after case/trailing-dot normalization),
        not by CIDR containment: a restore must undo exactly what a revoke
        pushed, never a broader or narrower range.
        """
        wanted = {_normalize_pattern(p) for p in host_patterns}
        kept: list[RevokeEntry] = []
        touched = 0
        with self._lock:
            for entry in self.entries:
                remaining = [
                    p for p in entry.host_patterns if _normalize_pattern(p) not in wanted
                ]
                if len(remaining) == len(entry.host_patterns):
                    kept.append(entry)
                    continue
                touched += 1
                if remaining:
                    entry.host_patterns = remaining
                    kept.append(entry)
            self.entries = kept
        return touched

    def clear_capability(self, capability_ref: str) -> int:
        """Drop every entry pushed for ``capability_ref``; returns entries removed."""
        with self._lock:
            kept = [e for e in self.entries if e.capability_ref != capability_ref]
            removed = len(self.entries) - len(kept)
            self.entries = kept
        return removed

    def is_host_revoked(self, host: str) -> bool:
        with self._lock:
            entries = list(self.entries)
        return any(
            host_matches_revoke_pattern(host, p)
            for entry in entries
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


class FlowTracker:
    """In-flight flows, so a revoke push can close what is already open.

    The addon registers a flow once its request passes policy and unregisters
    it when the response (or an error) ends it. Reads happen on the RPC server
    thread while mitmproxy's event loop writes, hence the lock.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._flows: dict[object, FlowLike] = {}

    @staticmethod
    def _key(flow: FlowLike) -> object:
        return getattr(flow, "id", None) or id(flow)

    def register(self, flow: FlowLike) -> None:
        with self._lock:
            self._flows[self._key(flow)] = flow

    def unregister(self, flow: FlowLike) -> None:
        with self._lock:
            self._flows.pop(self._key(flow), None)

    def active(self) -> list[FlowLike]:
        with self._lock:
            return list(self._flows.values())

    def __len__(self) -> int:
        with self._lock:
            return len(self._flows)


def flow_host(flow: FlowLike) -> str:
    """Destination host of a flow, or "" when it cannot be determined.

    mitmproxy's HTTPFlow carries the host on ``flow.request``; the flat
    ``flow.pretty_host`` form is what the close-policy protocol models.
    Accept both so tracked live flows and synthetic ones match alike.
    """
    request = getattr(flow, "request", None)
    for candidate in (getattr(request, "pretty_host", None), getattr(flow, "pretty_host", None)):
        if isinstance(candidate, str):
            return candidate
    return ""


def apply_close_to_flows(
    flows: list[FlowLike],
    host_patterns: list[str],
    close_policy: str,
    drain_seconds: int | None
) -> None:
    """Apply close policy to matching flows"""
    matching_flows = [
        flow for flow in flows
        if any(host_matches_revoke_pattern(flow_host(flow), pattern)
               for pattern in host_patterns)
    ]
    
    if close_policy == "immediate":
        for flow in matching_flows:
            flow.kill()
    elif close_policy in ("drain", "drain_deadline"):
        for flow in matching_flows:
            flow.metadata["sandcat_l7_drain"] = True
            if close_policy == "drain_deadline" and drain_seconds:
                # Bind the loop variable: a bare closure would capture the
                # name and kill only the last matching flow, repeatedly.
                timer = threading.Timer(
                    drain_seconds, lambda f=flow: _kill_if_still_open(f)
                )
                timer.daemon = True
                timer.start()
    # For "deny_new", no action needed on existing flows


def _kill_if_still_open(flow: FlowLike) -> None:
    """Helper to kill flow if it's still draining after deadline"""
    if flow.metadata.get("sandcat_l7_drain"):
        flow.kill()


logger = logging.getLogger(__name__)


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
    capability_ref = params.get("capability_ref")
    lease_id = params.get("lease_id")
    reason = params.get("reason")
    trigger = params.get("trigger")

    logger.info(
        "revoke_flows: capability_ref=%r lease_id=%r reason=%r trigger=%r "
        "close_policy=%r host_patterns=%r",
        capability_ref,
        lease_id,
        reason,
        trigger,
        policy,
        patterns,
    )
    
    # Apply revocation to state
    state.apply_revoke(patterns, policy, drain_seconds, capability_ref)
    
    # Apply close policy to active flows
    apply_close_to_flows(get_active_flows(), patterns, policy, drain_seconds)
    
    return {"revoked": True, "host_patterns": patterns, "close_policy": policy}


def handle_restore_flows(state: RevokeState, params: dict) -> dict:
    """Handle the mitmproxy.l7.restore_flows RPC method.

    Undoes a previous revoke push so a re-granted lease is reachable again.
    Already-closed flows are not resurrected; only the deny state is dropped.
    """
    patterns = params.get("host_patterns") or []
    capability_ref = params.get("capability_ref")
    if not patterns and capability_ref is None:
        raise ValueError(
            "restore_flows requires host_patterns or capability_ref"
        )

    cleared = 0
    if capability_ref is not None:
        cleared += state.clear_capability(capability_ref)
    if patterns:
        cleared += state.clear_patterns(patterns)

    logger.info(
        "restore_flows: capability_ref=%r reason=%r trigger=%r host_patterns=%r cleared=%d",
        capability_ref,
        params.get("reason"),
        params.get("trigger"),
        patterns,
        cleared,
    )

    return {
        "restored": True,
        "cleared": cleared,
        "host_patterns": patterns,
        "capability_ref": capability_ref,
    }


class RevokeRpcServer:
    """Unix JSON-RPC server for mitmproxy.l7.revoke_flows method"""
    
    def __init__(self, socket_path: Path | str, state: RevokeState, get_active_flows: Callable):
        self.socket_path = Path(socket_path)
        self.state = state
        self.get_active_flows = get_active_flows
        self.server_socket = None
        self.running = False
        self.accept_thread = None
        self._ready = threading.Event()
    
    def start(self):
        """Start the RPC server"""
        if self.running:
            return
        
        # Create parent directory if needed
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Remove existing socket file if it exists
        if self.socket_path.exists():
            self.socket_path.unlink()
        
        # Create and bind Unix socket
        self.server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_socket.bind(str(self.socket_path))
        
        # Set socket permissions to 0o600 (owner read/write only)
        os.chmod(str(self.socket_path), 0o600)
        
        self.server_socket.listen(5)
        self.running = True
        self._ready.set()
        
        # Start accept thread
        self.accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.accept_thread.start()

    def wait_ready(self, timeout: float = 2.0) -> bool:
        """Block until the socket is listening. Callers must not poll for the
        socket file: it exists between bind() and listen(), when connects fail."""
        return self._ready.wait(timeout)
    
    def stop(self):
        """Stop the RPC server"""
        if not self.running:
            return
        
        self.running = False
        self._ready.clear()
        
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
    
    def _send_jsonrpc_response(self, client_socket, response: dict) -> None:
        response_data = (json.dumps(response) + "\n").encode("utf-8")
        client_socket.sendall(response_data)

    def _handle_client(self, client_socket):
        """Handle a single client connection (one request per connection)"""
        request_id = None
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
            try:
                request = json.loads(line.decode("utf-8"))
            except json.JSONDecodeError as e:
                self._send_jsonrpc_response(
                    client_socket,
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {
                            "code": -32700,  # Parse error
                            "message": str(e),
                        },
                    },
                )
                return

            request_id = request.get("id")
            
            # Handle the JSON-RPC request
            response = self._handle_jsonrpc_request(request)
            
            # Send response
            self._send_jsonrpc_response(client_socket, response)
        
        except Exception as e:
            # Send error response
            error_response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,  # Internal error
                    "message": str(e)
                }
            }
            try:
                self._send_jsonrpc_response(client_socket, error_response)
            except OSError:
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
        try:
            if method == "mitmproxy.l7.revoke_flows":
                result = handle_revoke_flows(self.state, params, self.get_active_flows)
            elif method == "mitmproxy.l7.restore_flows":
                result = handle_restore_flows(self.state, params)
            else:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32601,  # Method not found
                        "message": f"Method not found: {method}"
                    }
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

        return {"jsonrpc": "2.0", "id": request_id, "result": result}