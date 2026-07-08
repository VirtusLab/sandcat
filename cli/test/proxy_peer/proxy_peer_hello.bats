#!/usr/bin/env bats

setup() {
	load test_helper
	export HELLO="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-hello.py"
}

teardown() {
	pkill -f "proxy-peer-hello.py --port 18080" || true
}

@test "proxy-peer-hello responds with JSON on /hello" {
	python3 "$HELLO" --port 18080 &
	sleep 0.5
	run curl -sf http://127.0.0.1:18080/hello
	assert_success
	assert_output --partial '"service": "proxy-peer"'
}
