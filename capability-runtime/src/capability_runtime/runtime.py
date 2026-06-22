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
    CapabilityNotVisible,
    CapabilityUnknown,
)
from capability_runtime.lease import LeaseManager
from capability_runtime.network import NetworkBinding
from capability_runtime.netbird_backend import NetBirdRevocationBackend
from capability_runtime.netbird_client import NetBirdClient
from capability_runtime.observability import ObservabilityCollector
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


class CapabilityRuntime:
    """Wire together catalog, leases, revocation, observability, discovery."""

    def __init__(
        self,
        trace_file: Path,
        trace_id: str,
        seed: int,
        policy_version: str = "1.0.0",
        netbird_client: NetBirdClient | None = None,
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

        # Register create_pr as DECLARED (invisible until leased)
        self.catalog.register("create_pr", CapabilityRef("cap-create-pr"), LifecycleState.DECLARED)

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
        agent_id: AgentIdentity,
        capability_ref: CapabilityRef,
        justification: str,
    ) -> LeaseDecision:
        """Grant lease with capability-specific params (spec §3.2.2)."""
        # Check capability exists
        state = self.catalog.get_state(capability_ref)
        if state not in (LifecycleState.DECLARED, LifecycleState.DISCOVERABLE, LifecycleState.VISIBLE):
            raise CapabilityUnknown(capability_ref)

        now = datetime.now(timezone.utc)

        capability_name = self.catalog.get_name(capability_ref)
        if capability_name == "write_note":
            quota = 3
            ttl = timedelta(minutes=5)
            token_budget = 10_000
            risk_envelope = "medium"
        else:
            # PoC 1 params for create_pr (default)
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
        self, target: Union[LeaseId, CapabilityRef], reason: str
    ) -> None:
        """Revoke capability by lease ID or ref (spec §3.2.3)."""
        physical_revocation = False
        
        if isinstance(target, LeaseId):
            self.revocation_manager.revoke_by_lease(target, reason)
            self.observability.emit_capability_event(
                {
                    "event": "capability_revoked",
                    "lease_id": target.value,
                    "reason": reason,
                }
            )
        else:
            # Check if this is a network capability
            binding = self.catalog.get_network_binding(target)
            if binding is not None and self._netbird_backend is not None:
                # Perform physical revocation via NetBird backend
                self._netbird_backend.revoke_binding(binding, reason)
                physical_revocation = True
            
            # Perform logical revocation
            self.revocation_manager.revoke_by_ref(target, reason)
            
            # Invalidate agent bundle cache
            self._bundle_version += 1
            
            self.observability.emit_capability_event(
                {
                    "event": "capability_revoked",
                    "capability_ref": target.value,
                    "reason": reason,
                    "physical_revocation": physical_revocation,
                }
            )

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

    def emit_execution_event(self, event: dict) -> None:
        """Emit execution event to observability (spec §3.2.5)."""
        self.observability.emit_execution_event(event)

    def emit_capability_event(self, event: dict) -> None:
        """Emit capability event to observability (spec §3.2.5)."""
        self.observability.emit_capability_event(event)

    def record_action(self, lease_id: LeaseId, now: datetime) -> None:
        """Decrement quota; revoke if exhausted (spec §3.2.6)."""
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
                self.catalog.set_state(lease.capability_ref, LifecycleState.EXPIRED)
                self.revocation_manager.revoke_by_lease(lease_id, "quota exhausted")

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
