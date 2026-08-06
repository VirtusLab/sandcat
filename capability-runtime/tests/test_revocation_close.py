from capability_runtime.network import NetworkBinding
from capability_runtime.revocation_close import (
    DEFAULT_DRAIN_SECONDS,
    RevocationClosePolicy,
    host_patterns_for_binding,
    resolve_close_policy,
)
from capability_runtime.types import CapabilityRef


def test_default_when_catalog_and_cli_absent_is_drain_deadline_30():
    policy, seconds = resolve_close_policy(
        catalog_policy=None,
        catalog_drain_seconds=None,
        trigger="unknown",
        cli_override=None,
    )
    assert policy is RevocationClosePolicy.DRAIN_DEADLINE
    assert seconds == DEFAULT_DRAIN_SECONDS


def test_trigger_heuristics_when_catalog_absent():
    assert resolve_close_policy(
        catalog_policy=None, catalog_drain_seconds=None,
        trigger="operator", cli_override=None,
    )[0] is RevocationClosePolicy.IMMEDIATE
    assert resolve_close_policy(
        catalog_policy=None, catalog_drain_seconds=None,
        trigger="quota_exhausted", cli_override=None,
    )[0] is RevocationClosePolicy.DRAIN
    assert resolve_close_policy(
        catalog_policy=None, catalog_drain_seconds=None,
        trigger="ttl_expired", cli_override=None,
    )[0] is RevocationClosePolicy.DRAIN
    assert resolve_close_policy(
        catalog_policy=None, catalog_drain_seconds=None,
        trigger="budget_breach", cli_override=None,
    )[0] is RevocationClosePolicy.IMMEDIATE


def test_catalog_beats_trigger_heuristic():
    policy, _ = resolve_close_policy(
        catalog_policy=RevocationClosePolicy.DENY_NEW,
        catalog_drain_seconds=None,
        trigger="operator",
        cli_override=None,
    )
    assert policy is RevocationClosePolicy.DENY_NEW


def test_cli_override_beats_catalog():
    policy, _ = resolve_close_policy(
        catalog_policy=RevocationClosePolicy.DRAIN,
        catalog_drain_seconds=60,
        trigger="quota_exhausted",
        cli_override=RevocationClosePolicy.IMMEDIATE,
    )
    assert policy is RevocationClosePolicy.IMMEDIATE


def test_drain_deadline_uses_catalog_seconds():
    policy, seconds = resolve_close_policy(
        catalog_policy=RevocationClosePolicy.DRAIN_DEADLINE,
        catalog_drain_seconds=12,
        trigger="operator",
        cli_override=None,
    )
    assert policy is RevocationClosePolicy.DRAIN_DEADLINE
    assert seconds == 12


def test_host_patterns_include_network_dns_label_peer_hostname():
    binding = NetworkBinding(
        capability_ref=CapabilityRef("cap-reach-api"),
        peer_id="peer-1",
        network="10.8.0.0/24",
        route_id=None,
        dns_label="peer-proxy.netbird.selfhosted",
        peer_hostname="sandcat-proxy",
    )
    patterns = host_patterns_for_binding(binding)
    assert patterns == [
        "10.8.0.0/24",
        "peer-proxy.netbird.selfhosted",
        "sandcat-proxy",
    ]
