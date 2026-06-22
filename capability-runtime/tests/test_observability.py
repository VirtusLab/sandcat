import json
from pathlib import Path
from capability_runtime.observability import ObservabilityCollector


def test_append_and_replay_capability_events(tmp_path: Path):
    trace_file = tmp_path / "trace.jsonl"
    obs = ObservabilityCollector(trace_file=trace_file, trace_id="trace-1", seed=42)
    obs.emit_capability_event({"type": "bundle_issued", "agent_id": "agent-1"})
    obs.emit_capability_event({"type": "lease_granted", "lease_id": "lease-1"})
    events = obs.replay(seed=42)
    assert len(events) == 2
    assert events[0]["type"] == "bundle_issued"
    assert events[1]["lease_id"] == "lease-1"


def test_replay_is_deterministic(tmp_path: Path):
    trace_file = tmp_path / "trace.jsonl"
    obs = ObservabilityCollector(trace_file=trace_file, trace_id="trace-1", seed=99)
    obs.emit_execution_event({"type": "action", "tool": "read_file"})
    first = obs.replay(seed=99)
    second = obs.replay(seed=99)
    assert first == second
