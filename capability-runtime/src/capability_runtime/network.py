from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Protocol

from capability_runtime.types import CapabilityRef


class SyncMode(StrEnum):
    ROUTE_ENABLE = "route_enable"
    ACL_POLICY = "acl_policy"
    PEER_REMOVE = "peer_remove"  # break-glass; Phase 3 compat


class RevocationClosePolicy(StrEnum):
    IMMEDIATE = "immediate"
    DRAIN = "drain"
    DRAIN_DEADLINE = "drain_deadline"
    DENY_NEW = "deny_new"


@dataclass
class NetworkBinding:
    capability_ref: CapabilityRef
    peer_id: str
    network: str
    route_id: str | None
    sync_mode: SyncMode = field(default=SyncMode.ROUTE_ENABLE)
    dns_label: str | None = field(default=None)
    peer_hostname: str | None = field(default=None)
    revoke_close_policy: RevocationClosePolicy | None = field(default=None)
    revoke_drain_seconds: int | None = field(default=None)


def sync_mode_from_catalog(entry: dict[str, Any]) -> SyncMode:
    """Parse sync_mode from a catalog capability entry (flat or nested binding)."""
    binding = entry.get("binding", entry)
    raw = binding.get("sync_mode", SyncMode.ROUTE_ENABLE)
    return SyncMode(raw)


class PhysicalRevocationBackend(Protocol):
    def revoke_peer(self, peer_id: str, reason: str) -> None: ...

    def revoke_route(self, route_id: str, reason: str) -> None: ...

    def grant_binding(self, binding: NetworkBinding) -> None: ...

    def revoke_binding(self, binding: NetworkBinding, reason: str) -> None: ...
