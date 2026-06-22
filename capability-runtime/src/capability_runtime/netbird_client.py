from __future__ import annotations

import json
import os
from typing import Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class NetBirdClient(Protocol):
    def list_peers(self) -> list[dict]: ...

    def list_routes(self) -> list[dict]: ...

    def remove_peer(self, peer_id: str) -> None: ...

    def remove_route(self, route_id: str) -> None: ...

    def peer_exists(self, peer_id: str) -> bool: ...

    def route_exists(self, route_id: str) -> bool: ...


class MockNetBirdClient:
    def __init__(
        self,
        peers: list[dict] | None = None,
        routes: list[dict] | None = None,
    ) -> None:
        self._peers = list(peers or [])
        self._routes = list(routes or [])

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

    def _management_base_url(self) -> str:
        base = self._management_url.rstrip("/")
        if base.endswith("/api"):
            base = base[: -len("/api")]
        return base

    def _require_token(self) -> str:
        if not self._token:
            raise RuntimeError("NB_API_TOKEN is required for NetBird REST API calls")
        return self._token

    def _request(self, method: str, path: str) -> list[dict]:
        url = f"{self._management_base_url()}{path}"
        request = Request(
            url,
            method=method,
            headers={
                "Authorization": f"Token {self._require_token()}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request) as response:
                body = response.read().decode()
        except HTTPError:
            raise

        if not body:
            return []
        data = json.loads(body)
        if isinstance(data, list):
            return data
        return [data]
