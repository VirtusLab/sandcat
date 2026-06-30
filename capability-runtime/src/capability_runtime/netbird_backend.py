from __future__ import annotations

from capability_runtime.netbird_client import NetBirdClient
from capability_runtime.network import NetworkBinding


class NetBirdRevocationBackend:
    def __init__(self, client: NetBirdClient) -> None:
        self._client = client

    def grant_binding(self, binding: NetworkBinding) -> NetworkBinding:
        """Enable a network binding via NetBird client.
        
        Returns the updated binding (may have a new route_id if one was created).
        """
        return self._client.enable_binding(binding)

    def revoke_binding(self, binding: NetworkBinding, reason: str) -> None:
        if binding.route_id:
            self.revoke_route(binding.route_id, reason)
        if binding.peer_id:
            self.revoke_peer(binding.peer_id, reason)

    def revoke_peer(self, peer_id: str, reason: str) -> None:
        self._client.remove_peer(peer_id)

    def revoke_route(self, route_id: str, reason: str) -> None:
        self._client.remove_route(route_id)
