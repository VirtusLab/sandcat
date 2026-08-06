import ipaddress
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parents[2] / "templates/devcontainer/sandcat/scripts"
sys.path.insert(0, str(SCRIPTS))

from l7_revoke_rpc import RevokeState, host_matches_revoke_pattern


def test_host_matches_cidr():
    assert host_matches_revoke_pattern("10.8.0.5", "10.8.0.0/24") is True
    assert host_matches_revoke_pattern("10.9.0.5", "10.8.0.0/24") is False


def test_host_matches_dns_label_exact():
    assert host_matches_revoke_pattern(
        "peer-proxy.netbird.selfhosted", "peer-proxy.netbird.selfhosted"
    ) is True


def test_apply_revoke_marks_hosts_denied():
    state = RevokeState()
    state.apply_revoke(
        host_patterns=["10.8.0.0/24", "api.example.com"],
        close_policy="deny_new",
        drain_seconds=None,
    )
    assert state.is_host_revoked("10.8.0.5") is True
    assert state.is_host_revoked("api.example.com") is True
    assert state.is_host_revoked("other.com") is False