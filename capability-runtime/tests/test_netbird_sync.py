"""Tests for NetBirdClient enable_binding / disable_binding."""

from __future__ import annotations

import json
from io import BytesIO
from urllib.error import HTTPError

from capability_runtime.netbird_client import MockNetBirdClient, RestNetBirdClient
from capability_runtime.network import NetworkBinding, SyncMode
from capability_runtime.types import CapabilityRef


def _binding(
    *,
    route_id: str | None = None,
    sync_mode: SyncMode = SyncMode.ROUTE_ENABLE,
) -> NetworkBinding:
    return NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-abc",
        network="10.8.0.0/24",
        route_id=route_id,
        sync_mode=sync_mode,
    )


def _route_record(**overrides: object) -> dict:
    route = {
        "id": "route-1",
        "network_type": "IPv4",
        "description": "sandcat route reach-api",
        "network_id": "reach-api",
        "enabled": False,
        "peer": "peer-abc",
        "network": "10.8.0.0/24",
        "metric": 9999,
        "masquerade": True,
        "groups": ["grp-test"],
        "keep_route": False,
    }
    route.update(overrides)
    return route


def test_mock_enable_binding_creates_route_when_missing_route_id():
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}])
    binding = _binding()

    updated = client.enable_binding(binding)

    assert updated.route_id is not None
    routes = client.list_routes()
    assert len(routes) == 1
    assert routes[0]["network"] == "10.8.0.0/24"
    assert routes[0]["peer"] == "peer-abc"
    assert routes[0]["enabled"] is True


def test_mock_enable_binding_enables_existing_route():
    client = MockNetBirdClient(
        routes=[
            {
                "id": "route-1",
                "network": "10.8.0.0/24",
                "peer": "peer-abc",
                "enabled": False,
            }
        ]
    )
    binding = _binding(route_id="route-1")

    client.enable_binding(binding)

    assert client.list_routes()[0]["enabled"] is True


def test_mock_enable_binding_peer_remove_is_noop():
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}])
    binding = _binding(sync_mode=SyncMode.PEER_REMOVE)

    updated = client.enable_binding(binding)

    assert updated == binding
    assert client.peer_exists("peer-abc")
    assert client.list_routes() == []


def test_mock_enable_binding_acl_policy_is_noop():
    client = MockNetBirdClient()
    binding = _binding(sync_mode=SyncMode.ACL_POLICY)

    updated = client.enable_binding(binding)

    assert updated == binding
    assert client.list_routes() == []


def test_mock_disable_binding_disables_route():
    client = MockNetBirdClient(
        routes=[
            {
                "id": "route-1",
                "network": "10.8.0.0/24",
                "peer": "peer-abc",
                "enabled": True,
            }
        ]
    )
    binding = _binding(route_id="route-1")

    client.disable_binding(binding)

    assert client.list_routes()[0]["enabled"] is False
    assert client.route_exists("route-1")


def test_mock_disable_binding_peer_remove_deletes_peer():
    client = MockNetBirdClient(peers=[{"id": "peer-abc"}])
    binding = _binding(sync_mode=SyncMode.PEER_REMOVE)

    client.disable_binding(binding)

    assert not client.peer_exists("peer-abc")


def test_mock_enable_after_disable_is_idempotent():
    client = MockNetBirdClient(
        routes=[
            {
                "id": "route-1",
                "network": "10.8.0.0/24",
                "peer": "peer-abc",
                "enabled": True,
            }
        ]
    )
    binding = _binding(route_id="route-1")

    client.disable_binding(binding)
    client.enable_binding(binding)

    assert client.list_routes()[0]["enabled"] is True


def test_rest_enable_binding_posts_route_when_no_route_id(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["method"] = request.get_method()
        captured["url"] = request.full_url
        captured["body"] = request.data.decode() if request.data else None
        if request.get_method() == "GET" and request.full_url.endswith("/api/routes"):
            return BytesIO(b"[]")
        return BytesIO(
            json.dumps(
                {
                    "id": "route-new",
                    "network": "10.8.0.0/24",
                    "peer": "peer-abc",
                    "enabled": True,
                }
            ).encode()
        )

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setenv("NB_ROUTE_GROUPS", "grp-test")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    updated = client.enable_binding(_binding())

    assert captured["method"] == "POST"
    assert captured["url"] == "https://api.netbird.io/api/routes"
    assert json.loads(captured["body"]) == {
        "description": "sandcat route reach-api",
        "network_id": "reach-api",
        "network": "10.8.0.0/24",
        "peer": "peer-abc",
        "enabled": True,
        "metric": 9999,
        "masquerade": True,
        "groups": ["grp-test"],
        "keep_route": False,
    }
    assert updated.route_id == "route-new"


def test_rest_enable_binding_puts_existing_route(monkeypatch):
    captured: dict = {}
    routes = [_route_record(id="route-1")]

    def fake_urlopen(request):
        captured["method"] = request.get_method()
        captured["url"] = request.full_url
        captured["body"] = request.data.decode() if request.data else None
        if request.get_method() == "GET" and request.full_url.endswith("/api/routes"):
            return BytesIO(json.dumps(routes).encode())
        if request.get_method() == "GET" and request.full_url.endswith("/api/routes/route-1"):
            return BytesIO(json.dumps(_route_record(id="route-1")).encode())
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    binding = _binding(route_id="route-1")
    updated = client.enable_binding(binding)

    assert captured["method"] == "PUT"
    assert captured["url"] == "https://api.netbird.io/api/routes/route-1"
    assert json.loads(captured["body"])["enabled"] is True
    assert updated.route_id == "route-1"


def test_rest_enable_binding_reuses_existing_route_without_route_id(monkeypatch):
    calls: list[tuple[str, str]] = []
    routes = [_route_record(id="route-existing")]

    def fake_urlopen(request):
        method = request.get_method()
        url = request.full_url
        calls.append((method, url))
        if method == "GET" and url.endswith("/api/routes"):
            return BytesIO(json.dumps(routes).encode())
        if method == "GET" and url.endswith("/api/routes/route-existing"):
            return BytesIO(json.dumps(_route_record(id="route-existing")).encode())
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    updated = client.enable_binding(_binding())

    assert ("PUT", "https://api.netbird.io/api/routes/route-existing") in calls
    assert updated.route_id == "route-existing"
    assert all(method != "POST" for method, _ in calls)


def test_rest_enable_binding_retries_put_after_duplicate_post(monkeypatch):
    calls: list[tuple[str, str]] = []
    route_list_calls = 0
    routes = [_route_record(id="route-existing")]

    def fake_urlopen(request):
        nonlocal route_list_calls
        method = request.get_method()
        url = request.full_url
        calls.append((method, url))
        if method == "GET" and url.endswith("/api/routes"):
            route_list_calls += 1
            if route_list_calls == 1:
                return BytesIO(b"[]")
            return BytesIO(json.dumps(routes).encode())
        if method == "GET" and url.endswith("/api/routes/route-existing"):
            return BytesIO(json.dumps(_route_record(id="route-existing")).encode())
        if method == "POST" and url.endswith("/api/routes"):
            raise HTTPError(
                url,
                422,
                "Unprocessable Entity",
                hdrs=None,
                fp=BytesIO(b'{"message":"route already exists","code":422}'),
            )
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setenv("NB_ROUTE_GROUPS", "grp-test")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    updated = client.enable_binding(_binding())

    assert ("POST", "https://api.netbird.io/api/routes") in calls
    assert ("PUT", "https://api.netbird.io/api/routes/route-existing") in calls
    assert updated.route_id == "route-existing"


def test_rest_disable_binding_puts_route_disabled(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["method"] = request.get_method()
        captured["url"] = request.full_url
        captured["body"] = request.data.decode() if request.data else None
        if request.get_method() == "GET":
            return BytesIO(json.dumps(_route_record(id="route-1", enabled=True)).encode())
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    client.disable_binding(_binding(route_id="route-1"))

    assert captured["method"] == "PUT"
    assert captured["url"] == "https://api.netbird.io/api/routes/route-1"
    assert json.loads(captured["body"])["enabled"] is False


def test_rest_disable_binding_peer_remove_deletes_peer(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["method"] = request.get_method()
        captured["url"] = request.full_url
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    client.disable_binding(_binding(sync_mode=SyncMode.PEER_REMOVE))

    assert captured["method"] == "DELETE"
    assert captured["url"] == "https://api.netbird.io/api/peers/peer-abc"
