from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.types import CapabilityRef


def test_register_and_query_visibility():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref, initial_state=LifecycleState.DECLARED)
    assert catalog.get_state(ref) == LifecycleState.DECLARED
    catalog.set_state(ref, LifecycleState.VISIBLE)
    assert catalog.is_visible(ref)
    assert not catalog.is_visible(CapabilityRef("missing"))


def test_discoverable_not_visible():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-secret")
    catalog.register("secret_tool", ref, initial_state=LifecycleState.DISCOVERABLE)
    assert catalog.is_discoverable(ref)
    assert not catalog.is_visible(ref)


def test_leased_is_visible():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-x")
    catalog.register("tool_x", ref, initial_state=LifecycleState.LEASED)
    assert catalog.is_visible(ref)


def test_get_by_name():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref)
    assert catalog.get_by_name("create_pr") == ref
    assert catalog.get_by_name("missing") is None
