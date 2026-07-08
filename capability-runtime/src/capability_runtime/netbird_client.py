from __future__ import annotations

import json
import os
from dataclasses import replace
from typing import Any, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from capability_runtime.network import NetworkBinding, SyncMode


def _default_network_id(network: str) -> str:
    """NetBird network_id (1-40 chars) derived from a CIDR."""
    return network.replace(".", "-").replace("/", "-")[:40]


DEFAULT_ROUTE_METRIC = 9999
DEFAULT_ROUTE_MASQUERADE = True
DEFAULT_ROUTE_KEEP_ROUTE = False


class NetBirdApiError(RuntimeError):
    def __init__(self, method: str, path: str, code: int, detail: str) -> None:
        self.method = method
        self.path = path
        self.code = code
        self.detail = detail
        super().__init__(
            f"NetBird API {method} {path} failed (HTTP {code}): {detail}"
        )


def _network_id_for_binding(binding: NetworkBinding) -> str:
    ref = binding.capability_ref.value
    if ref.startswith("cap-"):
        ref = ref[4:]
    slug = ref.replace("_", "-")[:40]
    if slug:
        return slug
    return _default_network_id(binding.network)


def _effective_route_id(route_id: str | None) -> str | None:
    """Treat template placeholders and empty strings as no route id."""
    if route_id is None:
        return None
    normalized = route_id.strip().lower()
    if normalized in {"", "route-placeholder", "peer-placeholder", "placeholder"}:
        return None
    return route_id.strip()


def build_route_create_payload(
    *,
    network: str,
    peer_id: str,
    network_id: str,
    groups: list[str],
    metric: int = DEFAULT_ROUTE_METRIC,
    masquerade: bool = DEFAULT_ROUTE_MASQUERADE,
    keep_route: bool = DEFAULT_ROUTE_KEEP_ROUTE,
) -> dict[str, Any]:
    """NetBird POST /api/routes body with all required fields."""
    if not groups:
        raise ValueError("route distribution groups must not be empty")
    return {
        "description": f"sandcat route {network_id}",
        "network_id": network_id,
        "enabled": True,
        "peer": peer_id,
        "network": network,
        "metric": metric,
        "masquerade": masquerade,
        "groups": groups,
        "keep_route": keep_route,
    }


_ROUTE_PUT_KEYS = (
    "description",
    "network_id",
    "enabled",
    "peer",
    "peer_groups",
    "network",
    "domains",
    "metric",
    "masquerade",
    "groups",
    "keep_route",
    "access_control_groups",
    "skip_auto_apply",
)


def route_put_body(route: dict[str, Any], *, enabled: bool | None = None) -> dict[str, Any]:
    """Build PUT /api/routes/{id} body from a GET route (NetBird has no PATCH)."""
    body: dict[str, Any] = {
        key: route[key] for key in _ROUTE_PUT_KEYS if key in route and route[key] is not None
    }
    if enabled is not None:
        body["enabled"] = enabled
    return body


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

        route_id = _effective_route_id(binding.route_id)
        if route_id:
            for route in self._routes:
                if route.get("id") == route_id:
                    route["enabled"] = True
                    return binding

        for route in self._routes:
            if (
                route.get("peer") == binding.peer_id
                and route.get("network") == binding.network
            ):
                route["enabled"] = True
                return replace(binding, route_id=route["id"])

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

    def list_groups(self, *, name: str | None = None) -> list[dict]:
        path = "/api/groups"
        if name:
            path = f"{path}?name={name}"
        return self._request("GET", path)

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

        route_id = _effective_route_id(binding.route_id)
        if route_id and self.route_exists(route_id):
            self._enable_route(route_id)
            return binding

        existing = self._find_route_for_binding(binding)
        if existing is not None:
            resolved_id = str(existing["id"])
            self._enable_route(resolved_id)
            return replace(binding, route_id=resolved_id)

        try:
            created = self._create_route(binding)
        except NetBirdApiError as exc:
            if exc.code == 422:
                existing = self._find_route_for_binding(binding)
                if existing is not None:
                    resolved_id = str(existing["id"])
                    self._enable_route(resolved_id)
                    return replace(binding, route_id=resolved_id)
            raise

        return replace(binding, route_id=created["id"])

    def _enable_route(self, route_id: str) -> None:
        self._set_route_enabled(route_id, True)

    def _set_route_enabled(self, route_id: str, enabled: bool) -> None:
        route = self._get_route(route_id)
        self._request(
            "PUT",
            f"/api/routes/{route_id}",
            route_put_body(route, enabled=enabled),
        )

    def _get_route(self, route_id: str) -> dict:
        return self._request("GET", f"/api/routes/{route_id}")[0]

    def _create_route(self, binding: NetworkBinding) -> dict:
        return self._request(
            "POST",
            "/api/routes",
            build_route_create_payload(
                network=binding.network,
                peer_id=binding.peer_id,
                network_id=_network_id_for_binding(binding),
                groups=self._resolve_route_distribution_groups(),
            ),
        )[0]

    def _find_route_for_binding(self, binding: NetworkBinding) -> dict | None:
        network_id = _network_id_for_binding(binding)
        for route in self.list_routes():
            if route.get("peer") != binding.peer_id:
                continue
            if route.get("network") == binding.network:
                return route
            if route.get("network_id") == network_id:
                return route
        return None

    def _http_error(self, method: str, path: str, exc: HTTPError) -> NetBirdApiError:
        detail = exc.read().decode() if exc.fp else ""
        return NetBirdApiError(method, path, exc.code, detail)

    def _resolve_route_distribution_groups(self) -> list[str]:
        from capability_runtime.settings import load_netbird_route_groups

        configured = load_netbird_route_groups()
        if configured:
            return configured

        groups = self.list_groups(name="All")
        for group in groups:
            if group.get("name") == "All" and group.get("id"):
                return [str(group["id"])]

        if not groups:
            groups = self.list_groups()
        if groups and groups[0].get("id"):
            return [str(groups[0]["id"])]

        raise RuntimeError(
            "No NetBird distribution groups found; set netbird_route_groups in "
            "settings or NB_ROUTE_GROUPS"
        )

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
        route_id = _effective_route_id(binding.route_id)
        if not route_id:
            return
        self._set_route_enabled(route_id, False)

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
        except HTTPError as exc:
            raise self._http_error(method, path, exc) from exc

        if not raw:
            return []
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return parsed
        return [parsed]
