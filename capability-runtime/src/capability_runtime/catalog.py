from __future__ import annotations

from enum import StrEnum

from capability_runtime.errors import CapabilityUnknown
from capability_runtime.types import CapabilityRef


class LifecycleState(StrEnum):
    DECLARED = "Declared"
    DISCOVERABLE = "Discoverable"
    VISIBLE = "Visible"
    LEASED = "Leased"
    EXPIRED = "Expired"
    REVOKED = "Revoked"
    ARCHIVED = "Archived"


class CapabilityCatalog:
    def __init__(self) -> None:
        self._by_ref: dict[CapabilityRef, LifecycleState] = {}
        self._by_name: dict[str, CapabilityRef] = {}
        self._name_by_ref: dict[CapabilityRef, str] = {}

    def register(
        self,
        name: str,
        ref: CapabilityRef,
        initial_state: LifecycleState = LifecycleState.DECLARED,
    ) -> None:
        self._by_name[name] = ref
        self._name_by_ref[ref] = name
        self._by_ref[ref] = initial_state

    def get_state(self, ref: CapabilityRef) -> LifecycleState:
        try:
            return self._by_ref[ref]
        except KeyError:
            raise CapabilityUnknown(ref) from None

    def set_state(self, ref: CapabilityRef, state: LifecycleState) -> None:
        if ref not in self._by_ref:
            raise CapabilityUnknown(ref)
        self._by_ref[ref] = state

    def is_visible(self, ref: CapabilityRef) -> bool:
        try:
            state = self._by_ref[ref]
        except KeyError:
            return False
        return state in (LifecycleState.VISIBLE, LifecycleState.LEASED)

    def is_discoverable(self, ref: CapabilityRef) -> bool:
        try:
            state = self._by_ref[ref]
        except KeyError:
            return False
        return state == LifecycleState.DISCOVERABLE

    def get_by_name(self, name: str) -> CapabilityRef | None:
        return self._by_name.get(name)

    def get_name(self, ref: CapabilityRef) -> str | None:
        return self._name_by_ref.get(ref)
