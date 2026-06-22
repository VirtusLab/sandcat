"""Tests for NetBird client (mock + REST)."""

from __future__ import annotations

import json
from io import BytesIO
from urllib.error import HTTPError

import pytest

from capability_runtime.netbird_client import MockNetBirdClient, RestNetBirdClient


def test_mock_client_tracks_peers_and_routes():
    client = MockNetBirdClient(
        peers=[{"id": "peer-abc", "connected": True}],
        routes=[{"id": "route-1", "network": "10.8.0.0/24"}],
    )
    assert client.peer_exists("peer-abc")
    assert client.list_peers() == [{"id": "peer-abc", "connected": True}]
    assert client.list_routes() == [{"id": "route-1", "network": "10.8.0.0/24"}]
    client.remove_peer("peer-abc")
    assert not client.peer_exists("peer-abc")
    assert client.list_peers() == []


def test_mock_remove_route():
    client = MockNetBirdClient(routes=[{"id": "route-1", "network": "10.8.0.0/24"}])
    assert client.route_exists("route-1")
    client.remove_route("route-1")
    assert not client.route_exists("route-1")
    assert client.list_routes() == []


def test_mock_defaults_to_empty_state():
    client = MockNetBirdClient()
    assert client.list_peers() == []
    assert client.list_routes() == []
    assert not client.peer_exists("missing")
    assert not client.route_exists("missing")


def test_rest_client_remove_peer(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["url"] = request.full_url
        captured["method"] = request.get_method()
        captured["headers"] = dict(request.header_items())
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setenv("NB_MANAGEMENT_URL", "https://api.netbird.io")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    client.remove_peer("peer-abc")

    assert captured["method"] == "DELETE"
    assert captured["url"] == "https://api.netbird.io/api/peers/peer-abc"
    assert captured["headers"]["Authorization"] == "Token test-token"


def test_rest_client_remove_route(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["url"] = request.full_url
        captured["method"] = request.get_method()
        return BytesIO(b"")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    client.remove_route("route-1")

    assert captured["method"] == "DELETE"
    assert captured["url"] == "https://api.netbird.io/api/routes/route-1"


def test_rest_client_list_peers(monkeypatch):
    peers = [{"id": "peer-abc", "connected": True}]

    def fake_urlopen(request):
        assert request.get_method() == "GET"
        assert request.full_url == "https://api.netbird.io/api/peers"
        return BytesIO(json.dumps(peers).encode())

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    assert client.list_peers() == peers


def test_rest_client_peer_exists(monkeypatch):
    peers = [{"id": "peer-abc", "connected": True}]

    def fake_urlopen(request):
        return BytesIO(json.dumps(peers).encode())

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    client = RestNetBirdClient()
    assert client.peer_exists("peer-abc")
    assert not client.peer_exists("peer-missing")


def test_rest_client_strips_trailing_slash_and_api_suffix(monkeypatch):
    captured: dict = {}

    def fake_urlopen(request):
        captured["url"] = request.full_url
        return BytesIO(b"[]")

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setenv("NB_MANAGEMENT_URL", "https://example.com/api/")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    RestNetBirdClient().list_peers()
    assert captured["url"] == "https://example.com/api/peers"


def test_rest_client_requires_api_token(monkeypatch):
    monkeypatch.delenv("NB_API_TOKEN", raising=False)
    with pytest.raises(RuntimeError, match="NB_API_TOKEN"):
        RestNetBirdClient().list_peers()


def test_rest_client_raises_on_http_error(monkeypatch):
    def fake_urlopen(request):
        raise HTTPError(
            request.full_url,
            404,
            "Not Found",
            hdrs=None,
            fp=BytesIO(b'{"message":"not found"}'),
        )

    monkeypatch.setenv("NB_API_TOKEN", "test-token")
    monkeypatch.setattr("capability_runtime.netbird_client.urlopen", fake_urlopen)

    with pytest.raises(HTTPError):
        RestNetBirdClient().remove_peer("peer-missing")
