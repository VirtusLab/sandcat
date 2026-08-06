"""CapabilityRuntime — all protocol surfaces (spec §3.2)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Union

from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.discover import (
    DiscoveryIntent,
    DiscoveryResult,
    discover_capabilities as _discover_capabilities,
)
from capability_runtime.errors import (
    BundleVersionMismatch,
    CallerIdentityMismatch,
    CapabilityNotVisible,
    CapabilityUnknown,
    LeaseExpired,
)
from capability_runtime.lease import LeaseManager
from capability_runtime.network import NetworkBinding, RevocationClosePolicy
from capability_runtime.netbird_backend import NetBirdRevocationBackend
from capability_runtime.netbird_client import NetBirdClient
from capability_runtime.netbird_sync import grant_network_binding
from capability_runtime.observability import ObservabilityCollector
from capability_runtime.policy import LeasePolicy, LeasePolicyNotFound, lease_policy_for, register_lease_policy
from capability_runtime.revoke import RevocationManager
from capability_runtime.types import (
    AgentIdentity,
    BudgetEnvelope,
    CapabilityBundle,
    CapabilityRef,
    LeaseDecision,
    LeaseId,
    NetworkCapability,
    ProvenanceRecord,
    ToolCapability,
)

_OPERATOR = AgentIdentity("operator")


def _assert_caller(caller: AgentIdentity, subject: AgentIdentity) -> None:
    if caller != subject:
        raise CallerIdentityMismatch(caller, subject)


class CapabilityRuntime:
    """Wire together catalog, leases, revocation, observability, discovery."""

    def __init__(
        self,
        trace_file: Path,
        trace_id: str,
        seed: int,
        policy_version: str = "1.0.0",
        netbird_client: NetBirdClient | None = None,
        l7_revoke_socket: Path | None = None,
    ):
        self.catalog = CapabilityCatalog()
        self.lease_manager = LeaseManager()
        self.revocation_manager = RevocationManager(self.catalog, self.lease_manager)
        self.observability = ObservabilityCollector(trace_file, trace_id, seed)
        self.policy_version = policy_version
        self.trace_id = trace_id
        self._bundle_version = 0
        self._current_bundles: dict[AgentIdentity, int] = {}
        self._netbird_client = netbird_client
        self._netbird_backend = (
            NetBirdRevocationBackend(netbird_client) if netbird_client is not None else None
        )
        self._l7_revoke_socket = l7_revoke_socket

        # Register create_pr as DECLARED (invisible until leased)
        self.catalog.register("create_pr", CapabilityRef("cap-create-pr"), LifecycleState.DECLARED)

    def _push_l7_for_binding(
        self,
        binding: NetworkBinding,
        *,
        reason: str,
        trigger: str,
        lease_id: str | None = None,
        cli_override: RevocationClosePolicy | None = None,
    ) -> None:
        """Push L7 revocation for a network binding."""
        from capability_runtime.revocation_close import resolve_close_policy, host_patterns_for_binding
        from capability_runtime.l7_revoke_push import push_l7_revocation, DEFAULT_REVOKE_SOCKET

        policy, drain_seconds = resolve_close_policy(
            catalog_policy=binding.revoke_close_policy,
            catalog_drain_seconds=binding.revoke_drain_seconds,
            trigger=trigger,
            cli_override=cli_override,
        )
        patterns = host_patterns_for_binding(binding)
        socket_path = self._l7_revoke_socket or DEFAULT_REVOKE_SOCKET
        # For IMMEDIATE policy, don't pass drain_seconds
        final_drain_seconds = drain_seconds if policy != RevocationClosePolicy.IMMEDIATE else None
        ok = push_l7_revocation(
            socket_path=socket_path,
            host_patterns=patterns,
            close_policy=policy,
            drain_seconds=final_drain_seconds,
            capability_ref=binding.capability_ref.value,
            lease_id=lease_id,
            reason=reason,
            trigger=trigger,
        )
        event = {
            "event": "l7_revoke_push" if ok else "l7_revoke_push_failed",
            "capability_ref": binding.capability_ref.value,
            "close_policy": str(policy),
            "host_patterns": patterns,
            "reason": reason,
            "trigger": trigger,
        }
        if lease_id is not None:
            event["lease_id"] = lease_id
        if drain_seconds is not None:
            event["drain_seconds"] = drain_seconds
        self.observability.emit_capability_event(event)

    def process_expired_network_leases(self, now: datetime | None = None) -> None:
        """Disable NetBird bindings for expired network leases (TTL hook)."""
        if self._netbird_backend is None:
            return

        from capability_runtime.netbird_sync import revoke_network_binding

        if now is None:
            now = datetime.now(timezone.utc)

        for lease_id, lease in list(self.lease_manager._leases.items()):
            if (
                self.lease_manager.is_expired(lease_id, now)
                and not self.revocation_manager.is_lease_revoked(lease_id)
                and not self.lease_manager.is_exhausted(lease_id)
            ):
                binding = self.catalog.get_network_binding(lease.capability_ref)
                if binding is None:
                    continue
                try:
                    revoke_network_binding(self._netbird_backend, binding, "TTL expired")
                    # Push L7 revocation after physical revoke
                    self._push_l7_for_binding(
                        binding,
                        reason="TTL expired",
                        trigger="ttl_expired",
                        lease_id=lease_id.value
                    )
                except Exception:
                    self.observability.emit_capability_event(
                        {
                            "event": "physical_sync_failed",
                            "lease_id": lease_id.value,
                            "capability_ref": lease.capability_ref.value,
                            "reason": "TTL expired",
                        }
                    )
                    continue
                self.revocation_manager.revoke_by_lease(lease_id, "TTL expired")
                self.catalog.set_state(lease.capability_ref, LifecycleState.EXPIRED)
                self.observability.emit_capability_event(
                    {
                        "event": "capability_revoked",
                        "lease_id": lease_id.value,
                        "capability_ref": lease.capability_ref.value,
                        "reason": "TTL expired",
                        "physical_sync": "disabled",
                    }
                )

    def next_network_lease_expiry(self, now: datetime | None = None) -> datetime | None:
        """Return earliest expiry among active network leases."""
        if now is None:
            now = datetime.now(timezone.utc)

        next_expiry: datetime | None = None
        for lease_id, lease in self.lease_manager._leases.items():
            if self.revocation_manager.is_lease_revoked(lease_id):
                continue
            if self.lease_manager.is_exhausted(lease_id):
                continue
            if self.catalog.get_network_binding(lease.capability_ref) is None:
                continue
            expiry = lease.expires_at
            if next_expiry is None or expiry < next_expiry:
                next_expiry = expiry
        return next_expiry

    def register_network_capability(
        self,
        name: str,
        ref: CapabilityRef,
        binding: NetworkBinding,
        initial_state: LifecycleState = LifecycleState.DECLARED,
    ) -> None:
        """Register a network capability with its binding."""
        self.catalog.register(name, ref, initial_state)
        self.catalog.set_network_binding(ref, binding)

    def register_lease_policy(self, capability_name: str, policy: LeasePolicy) -> None:
        """Register a lease policy for a capability by name."""
        register_lease_policy(capability_name, policy)

    def check_current_capabilities(
        self, agent_id: AgentIdentity, context: dict
    ) -> CapabilityBundle:
        """Return visible tools + active leased tools for agent (spec §3.2.1)."""
        self._bundle_version += 1
        self._current_bundles[agent_id] = self._bundle_version

        now = datetime.now(timezone.utc)
        tools: list[ToolCapability] = []
        networks: list[NetworkCapability] = []
        earliest_expiry: datetime | None = None

        # Iterate through catalog to find visible capabilities
        for ref in self.catalog._by_ref:
            state = self.catalog.get_state(ref)
            name = self.catalog.get_name(ref)
            if name is None:
                continue

            # Include if Visible OR has active lease
            if state == LifecycleState.VISIBLE:
                # Check if this is a network capability
                binding = self.catalog.get_network_binding(ref)
                if binding is not None:
                    networks.append(
                        NetworkCapability(
                            ref=ref,
                            name=name,
                            peer_id=binding.peer_id,
                            network=binding.network,
                            route_id=binding.route_id,
                            lease_id=None,
                            quota="unbounded",
                            expires_at=None,
                        )
                    )
                else:
                    tools.append(
                        ToolCapability(
                            ref=ref,
                            name=name,
                            lease_id=None,
                            quota="unbounded",
                            expires_at=None,
                        )
                    )
            elif state == LifecycleState.LEASED:
                # Find active lease for this agent
                for lease_id, lease in self.lease_manager._leases.items():
                    if (
                        lease.capability_ref == ref
                        and lease.agent_id == agent_id
                        and not self.lease_manager.is_expired(lease_id, now)
                        and not self.revocation_manager.is_lease_revoked(lease_id)
                        and not self.lease_manager.is_exhausted(lease_id)
                    ):
                        remaining = self.lease_manager._remaining_quota[lease_id]
                        # Check if this is a network capability
                        binding = self.catalog.get_network_binding(ref)
                        if binding is not None:
                            networks.append(
                                NetworkCapability(
                                    ref=ref,
                                    name=name,
                                    peer_id=binding.peer_id,
                                    network=binding.network,
                                    route_id=binding.route_id,
                                    lease_id=lease_id,
                                    quota=remaining,
                                    expires_at=lease.expires_at,
                                )
                            )
                        else:
                            tools.append(
                                ToolCapability(
                                    ref=ref,
                                    name=name,
                                    lease_id=lease_id,
                                    quota=remaining,
                                    expires_at=lease.expires_at,
                                )
                            )
                        if earliest_expiry is None or lease.expires_at < earliest_expiry:
                            earliest_expiry = lease.expires_at
                        break

        self.process_expired_network_leases(now)

        bundle = CapabilityBundle(
            agent_id=agent_id,
            issued_at=now,
            expires_at=earliest_expiry,
            tools=tools,
            rules=[],
            skills=[],
            policies=[],
            hooks=[],
            budgets=BudgetEnvelope(
                token_quota="unbounded",
                action_quota="unbounded",
                wall_time_ttl=None,
            ),
            provenance=ProvenanceRecord(
                issuer="CapabilityRuntime",
                policy_version=self.policy_version,
                trace_id=self.trace_id,
            ),
            networks=networks,
            version=self._bundle_version,
        )

        self.observability.emit_capability_event(
            {
                "event": "bundle_issued",
                "agent_id": agent_id.value,
                "bundle_version": self._bundle_version,
                "tool_count": len(tools),
            }
        )

        return bundle

    def request_capability_lease(
        self,
        caller: AgentIdentity,
        agent_id: AgentIdentity,
        capability_ref: CapabilityRef,
        justification: str,
    ) -> LeaseDecision:
        """Grant lease with capability-specific params (spec §3.2.2)."""
        _assert_caller(caller, agent_id)
        # Check capability exists
        state = self.catalog.get_state(capability_ref)
        # REVOKED is intentionally not leasable from the agent surface: operator
        # revoke acts as a durable stop until lifecycle state changes externally.
        leasable = {
            LifecycleState.DECLARED,
            LifecycleState.DISCOVERABLE,
            LifecycleState.VISIBLE,
            LifecycleState.EXPIRED,
        }
        if state not in leasable:
            raise CapabilityUnknown(capability_ref)

        # Save the original state for rollback in case of failure
        original_state = state
        now = datetime.now(timezone.utc)

        capability_name = self.catalog.get_name(capability_ref)
        try:
            policy = lease_policy_for(capability_name)
            quota = policy.quota
            ttl = policy.ttl
            token_budget = policy.token_budget
            risk_envelope = policy.risk_envelope
        except LeasePolicyNotFound:
            if capability_name == "write_note":
                quota = 3
                ttl = timedelta(minutes=5)
                token_budget = 10_000
                risk_envelope = "medium"
            else:
                quota = 1
                ttl = timedelta(minutes=10)
                token_budget = 25_000
                risk_envelope = "high"

        decision = self.lease_manager.grant(
            agent_id=agent_id,
            capability_ref=capability_ref,
            quota=quota,
            ttl=ttl,
            token_budget=token_budget,
            risk_envelope=risk_envelope,
            now=now,
        )

        # Set catalog state to LEASED
        self.catalog.set_state(capability_ref, LifecycleState.LEASED)

        # Check if this is a network capability that needs physical sync
        binding = self.catalog.get_network_binding(capability_ref)
        physical_sync_status = None
        
        if binding is not None and self._netbird_backend is not None:
            # Attempt to enable the binding via NetBird
            try:
                updated_binding = grant_network_binding(self._netbird_backend, binding)
                # Update the binding in catalog if route_id changed
                if updated_binding.route_id != binding.route_id:
                    self.catalog.set_network_binding(capability_ref, updated_binding)
                physical_sync_status = "enabled"
            except Exception as e:
                # Rollback on failure (fail closed)
                # 1. Revoke the lease
                self.lease_manager._leases.pop(decision.lease_id, None)
                self.lease_manager._remaining_quota.pop(decision.lease_id, None)
                # 2. Revert catalog state
                self.catalog.set_state(capability_ref, original_state)
                # Re-raise the exception
                raise

        # Emit appropriate event
        if physical_sync_status == "enabled":
            # Emit capability_leased event for network capabilities
            self.observability.emit_capability_event(
                {
                    "event": "capability_leased",
                    "agent_id": agent_id.value,
                    "capability_ref": capability_ref.value,
                    "lease_id": decision.lease_id.value,
                    "quota": quota,
                    "justification": justification,
                    "physical_sync": physical_sync_status,
                }
            )
        else:
            # Emit lease_granted event for tool capabilities
            self.observability.emit_capability_event(
                {
                    "event": "lease_granted",
                    "agent_id": agent_id.value,
                    "capability_ref": capability_ref.value,
                    "lease_id": decision.lease_id.value,
                    "quota": quota,
                    "justification": justification,
                }
            )

        return decision

    def revoke_capability(
        self,
        caller: AgentIdentity,
        target: Union[LeaseId, CapabilityRef],
        reason: str,
        *,
        close_policy: RevocationClosePolicy | None = None,
        trigger: str = "operator",
    ) -> None:
        """Revoke capability by lease ID or ref (spec §3.2.3)."""
        _assert_caller(caller, _OPERATOR)
        physical_revocation = False
        
        if isinstance(target, LeaseId):
            lease = self.lease_manager.get_lease(target)
            physical_sync: str | None = None
            capability_ref_value: str | None = None
            if lease is not None:
                capability_ref_value = lease.capability_ref.value
                binding = self.catalog.get_network_binding(lease.capability_ref)
                if binding is not None and self._netbird_backend is not None:
                    from capability_runtime.netbird_sync import revoke_network_binding

                    revoke_network_binding(self._netbird_backend, binding, reason)
                    physical_sync = "disabled"
                    physical_revocation = True
                    # Push L7 revocation after physical revoke
                    self._push_l7_for_binding(
                        binding, 
                        reason=reason, 
                        trigger=trigger,
                        lease_id=target.value,
                        cli_override=close_policy
                    )
            self.revocation_manager.revoke_by_lease(target, reason)
            self._bundle_version += 1
            event: dict[str, object] = {
                "event": "capability_revoked",
                "lease_id": target.value,
                "reason": reason,
                "physical_revocation": physical_revocation,
            }
            if capability_ref_value is not None:
                event["capability_ref"] = capability_ref_value
            if physical_sync is not None:
                event["physical_sync"] = physical_sync
            self.observability.emit_capability_event(event)
        else:
            # Check if this is a network capability
            binding = self.catalog.get_network_binding(target)
            physical_sync: str | None = None
            if binding is not None and self._netbird_backend is not None:
                from capability_runtime.netbird_sync import revoke_network_binding

                revoke_network_binding(self._netbird_backend, binding, reason)
                physical_sync = "disabled"
                physical_revocation = True
                # Push L7 revocation after physical revoke
                self._push_l7_for_binding(
                    binding,
                    reason=reason,
                    trigger=trigger,
                    cli_override=close_policy
                )

            # Perform logical revocation
            self.revocation_manager.revoke_by_ref(target, reason)

            # Invalidate agent bundle cache
            self._bundle_version += 1

            event = {
                "event": "capability_revoked",
                "capability_ref": target.value,
                "reason": reason,
                "physical_revocation": physical_revocation,
            }
            if physical_sync is not None:
                event["physical_sync"] = physical_sync
            self.observability.emit_capability_event(event)

    def revoke_from_physical(self, binding: NetworkBinding, reason: str) -> None:
        """Perform logical revoke when physical route already disappeared.
        
        This is called by RouteDisappearanceWatcher when it detects that a peer
        or route no longer exists in NetBird. Since the physical resource is
        already gone, we only perform logical revocation without calling the
        NetBird backend.
        
        Args:
            binding: The network binding that disappeared
            reason: Why the revocation occurred
        """
        # Perform logical revocation only (no NetBird API call)
        self.revocation_manager.revoke_by_ref(binding.capability_ref, reason)
        
        # Push L7 revocation (physical already gone, but L7 may still be active)
        self._push_l7_for_binding(
            binding,
            reason=reason,
            trigger="physical_reconcile"
        )
        
        # Invalidate agent bundle cache
        self._bundle_version += 1
        
        # Emit event with physical_trigger flag
        self.observability.emit_capability_event(
            {
                "event": "capability_revoked",
                "capability_ref": binding.capability_ref.value,
                "reason": reason,
                "physical_trigger": True,
            }
        )

    def discover_capabilities(
        self, agent_id: AgentIdentity, intent: DiscoveryIntent
    ) -> DiscoveryResult:
        """Discover capabilities by intent (spec §3.2.4)."""
        return _discover_capabilities(self.catalog, agent_id, intent)

    def record_action(
        self,
        caller: AgentIdentity,
        agent_id: AgentIdentity,
        lease_id: LeaseId,
        now: datetime,
    ) -> None:
        """Decrement quota; revoke if exhausted (spec §3.2.6)."""
        lease = self.lease_manager.get_lease(lease_id)
        if lease is None:
            raise LeaseExpired(lease_id)
        _assert_caller(caller, lease.agent_id)
        _assert_caller(agent_id, lease.agent_id)
        remaining = self.lease_manager.decrement_quota(lease_id, now)

        self.observability.emit_capability_event(
            {
                "event": "quota_decremented",
                "lease_id": lease_id.value,
                "remaining": remaining,
            }
        )

        # If exhausted, revoke lease and set appropriate state
        if remaining == 0:
            lease = self.lease_manager.get_lease(lease_id)
            if lease is not None:
                # Check if this is a network capability that needs physical sync
                binding = self.catalog.get_network_binding(lease.capability_ref)
                if binding is not None and self._netbird_backend is not None:
                    # Disable the binding via NetBird
                    from capability_runtime.netbird_sync import revoke_network_binding
                    revoke_network_binding(self._netbird_backend, binding, "quota exhausted")
                    # Push L7 revocation after physical revoke
                    self._push_l7_for_binding(
                        binding,
                        reason="quota exhausted",
                        trigger="quota_exhausted",
                        lease_id=lease_id.value
                    )
                
                self.catalog.set_state(lease.capability_ref, LifecycleState.EXPIRED)
                self.revocation_manager.revoke_by_lease(lease_id, "quota exhausted")
                self._bundle_version += 1
                self._current_bundles[agent_id] = self._bundle_version

    def enforce_action(
        self, agent_id: AgentIdentity, tool_name: str, bundle_version: int, now: datetime
    ) -> None:
        """Enforce action is allowed (spec §3.2.7)."""
        # Check bundle version
        current_version = self._current_bundles.get(agent_id)
        if current_version is None or bundle_version != current_version:
            raise BundleVersionMismatch(current_version or 0, bundle_version)

        # Check tool is in current bundle
        ref = self.catalog.get_by_name(tool_name)
        if ref is None or not self.catalog.is_visible(ref):
            # Also check if there's an active lease
            found = False
            if ref is not None:
                for lease_id, lease in self.lease_manager._leases.items():
                    if (
                        lease.capability_ref == ref
                        and lease.agent_id == agent_id
                        and not self.lease_manager.is_expired(lease_id, now)
                        and not self.revocation_manager.is_lease_revoked(lease_id)
                        and not self.lease_manager.is_exhausted(lease_id)
                    ):
                        found = True
                        break
            if not found:
                raise CapabilityNotVisible(ref or CapabilityRef(tool_name))
