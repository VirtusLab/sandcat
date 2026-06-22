from capability_runtime.catalog import CapabilityCatalog, LifecycleState
from capability_runtime.discover import DiscoveryIntent, discover_capabilities
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_discoverable_capability_returns_metadata_when_query_matches():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref, initial_state=LifecycleState.DISCOVERABLE)

    result = discover_capabilities(
        catalog,
        AgentIdentity("agent-1"),
        DiscoveryIntent(query="create"),
    )

    assert not result.denied
    assert len(result.capabilities) == 1
    cap = result.capabilities[0]
    assert cap["name"] == "create_pr"
    assert cap["ref"] == "cap-create-pr"
    assert "description" in cap


def test_declared_and_visible_capabilities_not_returned():
    catalog = CapabilityCatalog()
    declared_ref = CapabilityRef("cap-secret")
    visible_ref = CapabilityRef("cap-public")
    discoverable_ref = CapabilityRef("cap-findable")
    catalog.register("secret_tool", declared_ref, initial_state=LifecycleState.DECLARED)
    catalog.register("public_tool", visible_ref, initial_state=LifecycleState.VISIBLE)
    catalog.register("findable_tool", discoverable_ref, initial_state=LifecycleState.DISCOVERABLE)

    result = discover_capabilities(
        catalog,
        AgentIdentity("agent-1"),
        DiscoveryIntent(query="tool"),
    )

    assert not result.denied
    names = {cap["name"] for cap in result.capabilities}
    assert names == {"findable_tool"}


def test_no_match_returns_denied():
    catalog = CapabilityCatalog()
    ref = CapabilityRef("cap-create-pr")
    catalog.register("create_pr", ref, initial_state=LifecycleState.DISCOVERABLE)

    result = discover_capabilities(
        catalog,
        AgentIdentity("agent-1"),
        DiscoveryIntent(query="deploy"),
    )

    assert result.denied
    assert result.capabilities == []
