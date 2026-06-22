import pytest
from capability_runtime.errors import (
    CapabilityNotVisible,
    CapabilityUnknown,
    LeaseExpired,
    LeaseQuotaExceeded,
    BundleVersionMismatch,
)
from capability_runtime.types import CapabilityRef


def test_error_hierarchy():
    assert issubclass(CapabilityNotVisible, Exception)
    assert issubclass(LeaseQuotaExceeded, Exception)


def test_capability_not_visible_carries_ref():
    err = CapabilityNotVisible(CapabilityRef("cap-x"))
    assert err.capability_ref.value == "cap-x"
