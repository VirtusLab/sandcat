from __future__ import annotations

import ipaddress
import threading
from dataclasses import dataclass, field
from fnmatch import fnmatch
from typing import Protocol


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