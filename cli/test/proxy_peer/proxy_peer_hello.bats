#!/usr/bin/env bats

setup() {
	load test_helper
	export HELLO="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-hello.py"
}

teardown() {
	if [[ -n "${HELLO_PID:-}" ]]; then
		kill "$HELLO_PID" 2>/dev/null || true
		wait "$HELLO_PID" 2>/dev/null || true
	fi
}

@test "proxy-peer-hello responds with JSON on /hello" {
	# Avoid fixed-port flakes when another test/process already uses 18080.
	local port=$((18080 + (BATS_SUITE_TEST_NUMBER % 1000)))
	local hello_log="$BATS_TEST_TMPDIR/proxy-peer-hello.log"

	python3 "$HELLO" --port "$port" >"$hello_log" 2>&1 &
	HELLO_PID=$!
	export HELLO_PID

	for _ in $(seq 1 30); do
		if ! kill -0 "$HELLO_PID" 2>/dev/null; then
			run cat "$hello_log"
			assert_failure
		fi
		if curl -sf "http://127.0.0.1:${port}/hello" >/dev/null 2>&1; then
			break
		fi
		sleep 0.1
	done

	run curl -sf "http://127.0.0.1:${port}/hello"
	assert_success
	assert_output '{"service": "proxy-peer", "ok": true}'
}
