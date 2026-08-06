from __future__ import annotations

from capability_runtime.l7_revoke_push import push_l7_restore, push_l7_revocation
from capability_runtime.network import RevocationClosePolicy


def test_push_sends_mitmproxy_l7_revoke_flows(revoke_peer):
    peer = revoke_peer()

    ok = push_l7_revocation(
        socket_path=peer.socket_path,
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.IMMEDIATE,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="operator revoke",
        trigger="operator",
    )

    assert ok is True
    request = peer.wait()[0]
    assert request["method"] == "mitmproxy.l7.revoke_flows"
    assert request["params"]["host_patterns"] == ["10.8.0.0/24"]
    assert request["params"]["close_policy"] == "immediate"


def test_push_unreachable_returns_false(tmp_path):
    ok = push_l7_revocation(
        socket_path=tmp_path / "missing.sock",
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.DRAIN,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="quota exhausted",
        trigger="quota_exhausted",
    )
    assert ok is False


def test_push_survives_non_oserror_failures(tmp_path, monkeypatch):
    """A malformed reply must not propagate out of a best-effort push."""
    import capability_runtime.l7_revoke_push as module

    class _BrokenClient:
        def __init__(self, *args, **kwargs):
            pass

        def call(self, *args, **kwargs):
            raise ValueError("garbage on the wire")

    monkeypatch.setattr(module, "UnixRpcClient", _BrokenClient)

    ok = push_l7_revocation(
        socket_path=tmp_path / "any.sock",
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.DRAIN,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="operator revoke",
        trigger="operator",
    )
    assert ok is False


def test_push_reports_rpc_error_as_failure(revoke_peer, monkeypatch):
    import capability_runtime.l7_revoke_push as module

    class _ErrorClient:
        def __init__(self, *args, **kwargs):
            pass

        def call(self, *args, **kwargs):
            return {"jsonrpc": "2.0", "id": 1, "error": {"code": -32601}}

    monkeypatch.setattr(module, "UnixRpcClient", _ErrorClient)

    peer = revoke_peer()
    ok = push_l7_revocation(
        socket_path=peer.socket_path,
        host_patterns=["10.8.0.0/24"],
        close_policy=RevocationClosePolicy.DRAIN,
        drain_seconds=None,
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="operator revoke",
        trigger="operator",
    )
    assert ok is False


def test_restore_sends_mitmproxy_l7_restore_flows(revoke_peer):
    peer = revoke_peer()

    ok = push_l7_restore(
        socket_path=peer.socket_path,
        host_patterns=["10.8.0.0/24", "peer.netbird.selfhosted"],
        capability_ref="cap-reach-api",
        lease_id="lease-1",
        reason="lease granted",
        trigger="lease_granted",
    )

    assert ok is True
    request = peer.wait()[0]
    assert request["method"] == "mitmproxy.l7.restore_flows"
    assert request["params"]["host_patterns"] == [
        "10.8.0.0/24",
        "peer.netbird.selfhosted",
    ]
    assert request["params"]["capability_ref"] == "cap-reach-api"
    assert request["params"]["lease_id"] == "lease-1"


def test_restore_unreachable_returns_false(tmp_path):
    ok = push_l7_restore(
        socket_path=tmp_path / "missing.sock",
        host_patterns=["10.8.0.0/24"],
        capability_ref="cap-reach-api",
        lease_id=None,
        reason="lease granted",
        trigger="lease_granted",
    )
    assert ok is False
