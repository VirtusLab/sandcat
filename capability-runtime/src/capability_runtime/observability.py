from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class ObservabilityCollector:
    """Records execution and capability events for replay (spec §7)."""

    trace_file: Path
    trace_id: str
    seed: int
    _events: list[dict[str, Any]] = field(default_factory=list, init=False)

    def _append(self, kind: str, event: dict[str, Any]) -> None:
        record = {
            "kind": kind,
            "trace_id": self.trace_id,
            "seed": self.seed,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **event,
        }
        self._events.append(record)
        with self.trace_file.open("a") as f:
            f.write(json.dumps(record) + "\n")

    def emit_execution_event(self, event: dict[str, Any]) -> None:
        self._append("execution", event)

    def emit_capability_event(self, event: dict[str, Any]) -> None:
        self._append("capability", event)

    def replay(self, seed: int) -> list[dict[str, Any]]:
        if seed != self.seed:
            return []
        if self.trace_file.exists():
            lines = self.trace_file.read_text().strip().splitlines()
            return [json.loads(line) for line in lines if line]
        return list(self._events)
