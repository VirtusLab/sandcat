#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/composefile.bash"

	COMPOSE_DIR="$BATS_TEST_TMPDIR/devcontainer"
	mkdir -p "$COMPOSE_DIR/sandcat"
	cp "$SCT_TEMPLATEDIR/devcontainer/compose-all.yml" "$COMPOSE_DIR/compose-all.yml"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-capability.yml" "$COMPOSE_DIR/sandcat/compose-capability.yml"
}

teardown() {
	unstub_all
}

@test "enable_capability adds capability-runtime service include" {
	enable_capability "$COMPOSE_DIR"
	run yq '.include[] | select(.path == "sandcat/compose-capability.yml")' "$COMPOSE_DIR/compose-all.yml"
	[ "$status" -eq 0 ]
}

@test "enable_capability sets SANDCAT_AGENT_ID on agent service" {
	enable_capability "$COMPOSE_DIR"
	run yq '.services.agent.environment[] | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")' "$COMPOSE_DIR/compose-all.yml"
	[ "$status" -eq 0 ]
}

@test "enable_capability mounts capability socket outside wg-runtime path" {
	enable_capability "$COMPOSE_DIR"
	run yq '.services.agent.volumes[] | select(. == "capability-socket:/run/sandcat-capability:ro")' "$COMPOSE_DIR/compose-all.yml"
	[ "$status" -eq 0 ]
}

@test "enable_capability is idempotent" {
	enable_capability "$COMPOSE_DIR"
	enable_capability "$COMPOSE_DIR"

	run yq '[.include[] | select(.path == "sandcat/compose-capability.yml")] | length' "$COMPOSE_DIR/compose-all.yml"
	assert_output "1"

	run yq '[.services.agent.environment[] | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")] | length' "$COMPOSE_DIR/compose-all.yml"
	assert_output "1"
}
