#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/init
	source "$SCT_LIBEXECDIR/init/init"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR"
}

teardown() {
	unstub_all
}

@test "init rejects invalid --agent value" {
	run init --name my-project --agent "invalid" --path "$PROJECT_DIR"
	assert_failure
	assert_output --partial "Invalid agent: invalid"
}


@test "init rejects invalid --ide value" {
	run init --agent claude --ide "invalid" --name test --path "$PROJECT_DIR"
	assert_failure
	assert_output --partial "Invalid IDE: invalid (expected: vscode jetbrains none)"
}

@test "init accepts valid --ide value" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude jetbrains : :"
	stub devcontainer "--settings-file .sandcat/settings.json --project-path $PROJECT_DIR --agent claude --ide jetbrains --name test : :"

	run init --agent claude --ide jetbrains --name test --path "$PROJECT_DIR"
	assert_success
}

@test "init interactive flow (devcontainer mode)" {
	unset -f read_line
	unset -f select_option

	stub read_line "'Project name [empty for default]:' : echo ''"
	stub select_option \
		"'Select agent:' claude : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode"

	local expected_name
	expected_name=$(basename "$PROJECT_DIR")-sandbox-devcontainer
	local settings_file=".sandcat/settings.json"

	stub settings "$PROJECT_DIR/$settings_file claude vscode : :"
	stub devcontainer "--settings-file $settings_file --project-path $PROJECT_DIR --agent claude --ide vscode --name $expected_name : :"

	run init --path "$PROJECT_DIR"

	assert_success
}
