#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../lib/capability.bash
	source "$SCT_LIBDIR/capability.bash"

	CAPABILITY_CMD="$SCT_LIBEXECDIR/capability/capability"
	TEST_REPO="$BATS_TEST_TMPDIR/project"
	mkdir -p "$TEST_REPO/.devcontainer"
	printf 'services: {}\n' >"$TEST_REPO/.devcontainer/compose-all.yml"
	cd "$TEST_REPO"
}

teardown() {
	unstub_all
}

@test "capability check execs into capability-runtime container" {
	capability_compose_exec() { echo "EXEC $*"; }
	export -f capability_compose_exec
	run capability_check --agent devcontainer-agent
	assert_success
	assert_output --partial "capability.check"
}

@test "capability check forwards agent and context to compose exec" {
	capability_compose_exec() { echo "EXEC $*"; }
	export -f capability_compose_exec
	run capability_check --agent devcontainer-agent --context '{"task":"x"}'
	assert_success
	assert_output --partial "--agent-id devcontainer-agent"
	assert_output --partial '--context {"task":"x"}'
}

@test "capability lease requires --ref and --justification" {
	run bash "$CAPABILITY_CMD" lease --ref cap-reach-api
	assert_failure
	assert_output --partial "justification"
}

@test "capability lease execs into capability-runtime container" {
	capability_compose_exec() { echo "EXEC $*"; }
	export -f capability_compose_exec
	run capability_lease --ref cap-reach-api --justification "smoke test"
	assert_success
	assert_output --partial "capability.lease"
}

@test "capability revoke execs into capability-runtime container" {
	capability_compose_exec() { echo "EXEC $*"; }
	export -f capability_compose_exec
	run capability_revoke --ref cap-reach-api --reason policy
	assert_success
	assert_output --partial "capability.revoke"
}

@test "capability watch execs into capability-runtime container" {
	capability_compose_exec() { echo "EXEC $*"; }
	export -f capability_compose_exec
	run capability_watch
	assert_success
	assert_output --partial "watch"
}

@test "capability with unknown subcommand prints usage and fails" {
	run bash "$CAPABILITY_CMD" bogus
	assert_failure
	assert_output --partial "Usage"
}

@test "sandcat capability check routes subcommand through module dispatcher" {
	printf 'test\n' > "$SCT_ROOT/.version"
	stub docker \
		"compose -f $TEST_REPO/.devcontainer/compose-all.yml exec -T capability-runtime python -m capability_runtime.cli capability.check --agent-id devcontainer-agent --context {} : echo 'EXEC capability.check'"
	run bash "$SCT_ROOT/bin/sandcat" capability check --agent devcontainer-agent
	assert_success
	assert_output --partial "capability.check"
}

@test "capability lease then revoke flow execs both commands" {
	capability_compose_exec() {
		echo "EXEC $*"
	}
	export -f capability_compose_exec
	
	# Lease
	run capability_lease --ref cap-reach-api --justification "test flow"
	assert_success
	assert_output --partial "capability.lease"
	assert_output --partial "cap-reach-api"
	
	# Revoke
	run capability_revoke --ref cap-reach-api --reason "test complete"
	assert_success
	assert_output --partial "capability.revoke"
	assert_output --partial "cap-reach-api"
}
