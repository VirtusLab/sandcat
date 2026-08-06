#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/composefile.bash"

	COMPOSE_DIR="$BATS_TEST_TMPDIR/devcontainer"
	mkdir -p "$COMPOSE_DIR/sandcat"
	cp "$SCT_TEMPLATEDIR/devcontainer/compose-all.yml" "$COMPOSE_DIR/compose-all.yml"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-capability.yml" "$COMPOSE_DIR/sandcat/compose-capability.yml"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml" "$COMPOSE_DIR/sandcat/compose-proxy.yml"
}

teardown() {
	unstub_all
}

@test "enable_capability adds capability-runtime service include" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.include[] | select(.path == "sandcat/compose-capability.yml")' "$COMPOSE_DIR/compose-all.yml"
}

@test "enable_capability sets SANDCAT_AGENT_ID on agent service" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services.agent.environment[] | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")' "$COMPOSE_DIR/compose-all.yml"
}

@test "enable_capability mounts capability socket outside wg-runtime path" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services.agent.volumes[] | select(. == "capability-socket:/run/sandcat-capability:ro")' "$COMPOSE_DIR/compose-all.yml"
}

@test "enable_capability adds capability-runtime to agent depends_on" {
	enable_capability "$COMPOSE_DIR"
	run yq '.services.agent.depends_on.capability-runtime.condition' "$COMPOSE_DIR/compose-all.yml"
	assert_success
	assert_output "service_started"
}

@test "enable_capability is idempotent" {
	enable_capability "$COMPOSE_DIR"
	enable_capability "$COMPOSE_DIR"

	run yq '[.include[] | select(.path == "sandcat/compose-capability.yml")] | length' "$COMPOSE_DIR/compose-all.yml"
	assert_output "1"

	run yq '[.services.agent.environment[] | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")] | length' "$COMPOSE_DIR/compose-all.yml"
	assert_output "1"
}

@test "enable_capability mounts capability admin socket into mitmproxy" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services.mitmproxy.volumes[] | select(. == "capability-socket:/run/sandcat-capability")' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
	yq -e '.services.mitmproxy.volumes[] | select(. == "./scripts/l7_record_client.py:/scripts/l7_record_client.py:ro")' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
	yq -e '.volumes.capability-socket' "$COMPOSE_DIR/sandcat/compose-proxy.yml"
}

@test "enable_capability passes CAPABILITY_L7_RECORD through mitmproxy" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services.mitmproxy.environment[] | select(. == "CAPABILITY_L7_RECORD")' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
	yq -e '.services.mitmproxy.environment[] | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
}

@test "enable_capability mounts mitmproxy-config into capability-runtime" {
	enable_capability "$COMPOSE_DIR"
	run yq '[.services."capability-runtime".volumes[]? | select(test("mitmproxy-config")) ] | length' \
		"$COMPOSE_DIR/sandcat/compose-capability.yml"
	assert_success
	[[ "$output" != "0" ]]
}

@test "enable_capability sets MITMPROXY_REVOKE_SOCKET on capability-runtime" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services."capability-runtime".environment[] | select(. == "MITMPROXY_REVOKE_SOCKET=/mitmproxy-config/l7-revoke.sock")' \
		"$COMPOSE_DIR/sandcat/compose-capability.yml"
}

@test "enable_capability mounts l7_revoke_rpc into mitmproxy" {
	enable_capability "$COMPOSE_DIR"
	run yq '[.services.mitmproxy.volumes[]? | select(test("l7_revoke_rpc")) ] | length' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
	assert_success
	[[ "$output" != "0" ]]
}

@test "enable_capability sets MITMPROXY_REVOKE_SOCKET on mitmproxy" {
	enable_capability "$COMPOSE_DIR"
	yq -e '.services.mitmproxy.environment[] | select(. == "MITMPROXY_REVOKE_SOCKET=/home/mitmproxy/.mitmproxy/l7-revoke.sock")' \
		"$COMPOSE_DIR/sandcat/compose-proxy.yml"
}
