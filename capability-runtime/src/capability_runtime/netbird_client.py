from __future__ import annotations

import json
import os
from dataclasses import replace
from typing import Any, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from capability_runtime.network import NetworkBinding, SyncMode


class NetBirdClient(Protocol):
    def list_peers(self) -> list[dict]: ...

    def list_routes(self) -> list[dict]: ...

    def remove_peer(self, peer_id: str) -> None: ...

    def remove_route(self, route_id: str) -> None: ...

    def peer_exists(self, peer_id: str) -> bool: ...

    def route_exists(self, route_id: str) -> bool: ...

    def get_route_state(self, binding: NetworkBinding) -> str: ...

    def enable_binding(self, binding: NetworkBinding) -> NetworkBinding: ...

    def disable_binding(self, binding: NetworkBinding) -> None: ...


class MockNetBirdClient:
    def __init__(
        self,
        peers: list[dict] | None = None,
        routes: list[dict] | None = None,
    ) -> None:
        self._peers = list(peers or [])
        self._routes = list(routes or [])
        self._next_route_id = 1

    def list_peers(self) -> list[dict]:
        return list(self._peers)

    def list_routes(self) -> list[dict]:
        return list(self._routes)

    def remove_peer(self, peer_id: str) -> None:
        self._peers = [peer for peer in self._peers if peer.get("id") != peer_id]

    def remove_route(self, route_id: str) -> None:
        self._routes = [route for route in self._routes if route.get("id") != route_id]

    def peer_exists(self, peer_id: str) -> bool:
        return any(peer.get("id") == peer_id for peer in self._peers)

    def route_exists(self, route_id: str) -> bool:
        return any(route.get("id") == route_id for route in self._routes)

    def get_route_state(self, binding: NetworkBinding) -> str:
        if not binding.route_id:
            return "missing"
        for route in self._routes:
            if route.get("id") == binding.route_id:
                return "disabled" if route.get("enabled") is False else "enabled"
        return "missing"

    def enable_binding(self, binding: NetworkBinding) -> NetworkBinding:
        if binding.sync_mode is SyncMode.PEER_REMOVE:
            return binding
        if binding.sync_mode is SyncMode.ACL_POLICY:
            # ACL policy sync deferred to a future phase.
            return binding
        if binding.sync_mode is not SyncMode.ROUTE_ENABLE:
            return binding

        if binding.route_id:
            for route in self._routes:
                if route.get("id") == binding.route_id:
                    route["enabled"] = True
            return binding

        route_id = f"route-{self._next_route_id}"
        self._next_route_id += 1
        self._routes.append(
            {
                "id": route_id,
                "network": binding.network,
                "peer": binding.peer_id,
                "enabled": True,
            }
        )
        return replace(binding, route_id=route_id)

    def disable_binding(self, binding: NetworkBinding) -> None:
        if binding.sync_mode is SyncMode.PEER_REMOVE:
            if binding.peer_id:
                self.remove_peer(binding.peer_id)
            return
        if binding.sync_mode is SyncMode.ACL_POLICY:
            # ACL policy sync deferred to a future phase.
            return
        if binding.sync_mode is not SyncMode.ROUTE_ENABLE:
            return

        if not binding.route_id:
            return
        for route in self._routes:
            if route.get("id") == binding.route_id:
                route["enabled"] = False
                return


class RestNetBirdClient:
    def __init__(
        self,
        *,
        api_token: str | None = None,
        management_url: str | None = None,
    ) -> None:
        self._token = api_token if api_token is not None else os.environ.get("NB_API_TOKEN")
        self._management_url = (
            management_url
            if management_url is not None
            else os.environ.get("NB_MANAGEMENT_URL", "https://api.netbird.io")
        )

    @classmethod
    def from_settings(cls) -> RestNetBirdClient:
        from capability_runtime.settings import load_netbird_credentials

        creds = load_netbird_credentials()
        return cls(api_token=creds.api_token, management_url=creds.management_url)

    def list_peers(self) -> list[dict]:
        return self._request("GET", "/api/peers")

    def list_routes(self) -> list[dict]:
        return self._request("GET", "/api/routes")

    def remove_peer(self, peer_id: str) -> None:
        self._request("DELETE", f"/api/peers/{peer_id}")

    def remove_route(self, route_id: str) -> None:
        self._request("DELETE", f"/api/routes/{route_id}")

    def peer_exists(self, peer_id: str) -> bool:
        return any(peer.get("id") == peer_id for peer in self.list_peers())

    def route_exists(self, route_id: str) -> bool:
        return any(route.get("id") == route_id for route in self.list_routes())

    def get_route_state(self, binding: NetworkBinding) -> str:
        if not binding.route_id:
            return "missing"
        for route in self.list_routes():
            if route.get("id") == binding.route_id:
                return "disabled" if route.get("enabled") is False else "enabled"
        return "missing"

    def enable_binding(self, binding: NetworkBinding) -> NetworkBinding:
        if binding.sync_mode is SyncMode.PEER_REMOVE:
            return binding
        if binding.sync_mode is SyncMode.ACL_POLICY:
            # ACL policy sync deferred to a future phase.
            return binding
        if binding.sync_mode is not SyncMode.ROUTE_ENABLE:
            return binding

        if binding.route_id:
            self._request(
                "PATCH",
                f"/api/routes/{binding.route_id}",
                {"enabled": True},
            )
            return binding

        created = self._request(
            "POST",
            "/api/routes",
            {
                "network": binding.network,
                "peer": binding.peer_id,
                "enabled": True,
            },
        )[0]
        return replace(binding, route_id=created["id"])

    def disable_binding(self, binding: NetworkBinding) -> None:
        if binding.sync_mode is SyncMode.PEER_REMOVE:
            if binding.peer_id:
                self.remove_peer(binding.peer_id)
            return
        if binding.sync_mode is SyncMode.ACL_POLICY:
            # ACL policy sync deferred to a future phase.
            return
        if binding.sync_mode is not SyncMode.ROUTE_ENABLE:
            return

        if not binding.route_id:
            return
        self._request(
            "PATCH",
            f"/api/routes/{binding.route_id}",
            {"enabled": False},
        )

    def _management_base_url(self) -> str:
        base = self._management_url.rstrip("/")
        if base.endswith("/api"):
            base = base[: -len("/api")]
        return base

    def _require_token(self) -> str:
        if not self._token:
            raise RuntimeError("NB_API_TOKEN is required for NetBird REST API calls")
        return self._token

    def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> list[dict]:
        url = f"{self._management_base_url()}{path}"
        data = json.dumps(body).encode() if body is not None else None
        request = Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Token {self._require_token()}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request) as response:
                raw = response.read().decode()
        except HTTPError:
            raise

        if not raw:
            return []
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return parsed
        return [parsed]
