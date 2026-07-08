#!/usr/bin/env bats

setup() {
	load "$BATS_TEST_DIRNAME/../composefile/test_helper"
}

@test "l7_record_client builds valid JSON-RPC payload" {
	local script="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/l7_record_client.py"

	[[ -f "$script" ]]

	run python3 - "$script" <<'PY'
import importlib.util
import json
import socket
import sys
from unittest.mock import patch

script = sys.argv[1]
spec = importlib.util.spec_from_file_location("l7_record_client", script)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

sent = []

class FakeSock:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def settimeout(self, _timeout):
        pass

    def connect(self, _addr):
        pass

    def sendall(self, data):
        sent.append(data)

with patch.object(socket, "socket", return_value=FakeSock()):
    mod.record_flow(
        agent_id="test-agent",
        host="100.64.0.5",
        method="GET",
        status=200,
    )

payload = json.loads(sent[0].decode().strip())
assert payload["jsonrpc"] == "2.0"
assert payload["id"] == 1
assert payload["method"] == "capability.l7.record"
assert payload["params"] == {
    "agent_id": "test-agent",
    "host": "100.64.0.5",
    "method": "GET",
    "status": 200,
}
print("ok")
PY
	assert_success
	assert_output "ok"
}
