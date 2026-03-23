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
	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json claude jetbrains : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide jetbrains --name test --stacks * --proxy web : :"

	run init --agent claude --ide jetbrains --name test --path "$PROJECT_DIR" --stacks "" --proxy web
	assert_success
}

@test "init accepts valid --stacks value" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path $PROJECT_DIR --agent claude --ide vscode --name test --stacks 'python rust' --proxy web : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "python,rust" --proxy web
	assert_success
}

@test "init rejects invalid --stacks value" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "python,invalid"
	assert_failure
	assert_output --partial "Invalid stack: invalid"
}

@test "init resolves scala dependency to java" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path $PROJECT_DIR --agent claude --ide vscode --name test --stacks 'java scala' --proxy web : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "scala" --proxy web
	assert_success
}

@test "init interactive flow (devcontainer mode)" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' tui 1password : echo ''" \
		"'Select development stacks (comma-separated numbers, empty for none):' node python java rust go scala ruby dotnet : echo ''"

	local expected_name
	expected_name=$(basename "$PROJECT_DIR")-sandbox
	local settings_file=".sandcat/settings.json"

	stub settings "$PROJECT_DIR/$settings_file claude vscode : :"
	stub devcontainer \
		"--settings-file $settings_file --project-path $PROJECT_DIR --agent claude --ide vscode --name $expected_name --stacks '' --proxy web : :"

	run init --path "$PROJECT_DIR"

	assert_success
}
