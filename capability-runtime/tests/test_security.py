"""Security boundary tests for capability runtime (spec §4)."""

from __future__ import annotations

import threading

import pytest

from capability_runtime.agent_loop import AgentExecutionLoop
from capability_runtime.errors import CallerIdentityMismatch
from capability_runtime.runtime import CapabilityRuntime
from capability_runtime.types import AgentIdentity, CapabilityRef


def test_request_lease_rejects_caller_impersonation(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-1", 300)
    victim = AgentIdentity("victim-agent")
    attacker = AgentIdentity("attacker-agent")

    with pytest.raises(CallerIdentityMismatch):
        runtime.request_capability_lease(
            attacker, victim, CapabilityRef("cap-create-pr"), "forged lease"
        )


def test_record_action_rejects_wrong_caller(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-2", 301)
    owner = AgentIdentity("owner-agent")
    other = AgentIdentity("other-agent")

    decision = runtime.request_capability_lease(
        owner, owner, CapabilityRef("cap-create-pr"), "legitimate lease"
    )

    with pytest.raises(CallerIdentityMismatch):
        runtime.record_action(other, owner, decision.lease_id, decision.granted_at)


def test_revoke_rejects_wrong_caller(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-3", 302)
    owner = AgentIdentity("owner-agent")
    other = AgentIdentity("other-agent")

    decision = runtime.request_capability_lease(
        owner, owner, CapabilityRef("cap-create-pr"), "legitimate lease"
    )

    with pytest.raises(CallerIdentityMismatch):
        runtime.revoke_capability(other, decision.lease_id, "forged revoke")


def test_forgeable_emit_api_removed(tmp_path):
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-4", 303)
    assert not hasattr(runtime, "emit_execution_event")
    assert not hasattr(runtime, "emit_capability_event")


def test_concurrent_run_step_respects_quota_one(tmp_path):
    """Two threads cannot both consume quota=1 on the same lease."""
    runtime = CapabilityRuntime(tmp_path / "trace.jsonl", "trace-sec-5", 304)
    loop = AgentExecutionLoop(runtime)
    agent = AgentIdentity("agent-concurrent")

    runtime.request_capability_lease(
        agent, agent, CapabilityRef("cap-create-pr"), "single-use lease"
    )

    barrier = threading.Barrier(2)
    outcomes: list[str] = []
    lock = threading.Lock()

    def worker(label: str) -> None:
        barrier.wait()
        try:
            loop.run_step(agent, {}, "create_pr", lambda: label)
            with lock:
                outcomes.append(f"ok:{label}")
        except Exception as exc:
            with lock:
                outcomes.append(type(exc).__name__)

    t1 = threading.Thread(target=worker, args=("a",))
    t2 = threading.Thread(target=worker, args=("b",))
    t1.start()
    t2.start()
    t1.join()
    t2.join()

    successes = [o for o in outcomes if o.startswith("ok:")]
    assert len(successes) == 1
