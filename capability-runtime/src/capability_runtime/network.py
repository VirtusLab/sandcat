from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from capability_runtime.types import CapabilityRef


@dataclass
class NetworkBinding:
    capability_ref: CapabilityRef
    peer_id: str
    network: str
    route_id: str | None


class PhysicalRevocationBackend(Protocol):
    def revoke_peer(self, peer_id: str, reason: str) -> None: ...

    def revoke_route(self, route_id: str, reason: str) -> None: ...
