from capability_runtime.types import AgentIdentity, CapabilityRef, LeaseId


class CapabilityRuntimeError(Exception):
    """Base for all typed runtime failures (spec §3.3)."""


class CapabilityNotVisible(CapabilityRuntimeError):
    def __init__(self, capability_ref: CapabilityRef):
        self.capability_ref = capability_ref
        super().__init__(f"Capability not visible: {capability_ref.value}")


class CapabilityUnknown(CapabilityRuntimeError):
    def __init__(self, capability_ref: CapabilityRef):
        self.capability_ref = capability_ref
        super().__init__(f"Unknown capability: {capability_ref.value}")


class LeaseExpired(CapabilityRuntimeError):
    def __init__(self, lease_id: LeaseId):
        self.lease_id = lease_id
        super().__init__(f"Lease expired: {lease_id.value}")


class LeaseQuotaExceeded(CapabilityRuntimeError):
    def __init__(self, capability_ref: CapabilityRef, lease_id: LeaseId):
        self.capability_ref = capability_ref
        self.lease_id = lease_id
        super().__init__(f"Lease quota exceeded for {capability_ref.value}")


class BundleVersionMismatch(CapabilityRuntimeError):
    def __init__(self, expected: int, actual: int):
        self.expected = expected
        self.actual = actual
        super().__init__(f"Bundle version mismatch: expected {expected}, got {actual}")


class CallerIdentityMismatch(CapabilityRuntimeError):
    def __init__(self, caller: AgentIdentity, subject: AgentIdentity):
        self.caller = caller
        self.subject = subject
        super().__init__(
            f"Caller identity mismatch: {caller.value} != {subject.value}"
        )
