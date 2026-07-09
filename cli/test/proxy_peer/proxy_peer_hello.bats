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
	python3 "$HELLO" --port 18080 &
	HELLO_PID=$!
	export HELLO_PID

	for _ in $(seq 1 20); do
		if curl -sf http://127.0.0.1:18080/hello >/dev/null 2>&1; then
			break
		fi
		sleep 0.1
	done

	run curl -sf http://127.0.0.1:18080/hello
	assert_success
	assert_output '{"service": "proxy-peer", "ok": true}'
}
