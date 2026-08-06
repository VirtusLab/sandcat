from __future__ import annotations

from capability_runtime.network import NetworkBinding, RevocationClosePolicy

DEFAULT_DRAIN_SECONDS = 30

_TRIGGER_PREFERRED: dict[str, RevocationClosePolicy] = {
    "operator": RevocationClosePolicy.IMMEDIATE,
    "quota_exhausted": RevocationClosePolicy.DRAIN,
    "ttl_expired": RevocationClosePolicy.DRAIN,
    "budget_breach": RevocationClosePolicy.IMMEDIATE,
}


def resolve_close_policy(
    *,
    catalog_policy: RevocationClosePolicy | None,
    catalog_drain_seconds: int | None,
    trigger: str,
    cli_override: RevocationClosePolicy | None,
) -> tuple[RevocationClosePolicy, int | None]:
    if cli_override is not None:
        policy = cli_override
    elif catalog_policy is not None:
        policy = catalog_policy
    else:
        policy = _TRIGGER_PREFERRED.get(trigger, RevocationClosePolicy.DRAIN_DEADLINE)

    if policy is RevocationClosePolicy.DRAIN_DEADLINE:
        seconds = (
            catalog_drain_seconds
            if catalog_drain_seconds is not None
            else DEFAULT_DRAIN_SECONDS
        )
    else:
        seconds = catalog_drain_seconds
    return policy, seconds


def host_patterns_for_binding(binding: NetworkBinding) -> list[str]:
    patterns = [binding.network]
    if binding.dns_label:
        patterns.append(binding.dns_label)
    if binding.peer_hostname:
        patterns.append(binding.peer_hostname)
    return patterns
