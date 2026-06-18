#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/init
	source "$SCT_LIBEXECDIR/init/init"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR"

	# Isolate from host user settings (e.g. op_service_account_token)
	SCT_HOME_DIR="$BATS_TEST_TMPDIR/config/sandcat"
	mkdir -p "$SCT_HOME_DIR"
	sct_home() { echo "$SCT_HOME_DIR"; }
	export -f sct_home

	# Isolate $HOME so ensure_host_agent_config_paths doesn't poke the real
	# user's ~/.claude / ~/.cursor while running the test suite.
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
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
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide jetbrains --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide jetbrains --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init accepts cursor as valid --agent value" {
	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json cursor vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent cursor --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent cursor --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init rejects invalid --secret-provider value" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider invalid
	assert_failure
	assert_output --partial "Invalid secret provider: invalid (expected: none 1password protonpass)"
}

@test "init rejects combining --1password and --secret-provider" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider protonpass --1password
	assert_failure
	assert_output --partial "Do not combine --1password with --secret-provider"
}

@test "init accepts --sp as alias for --secret-provider" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider protonpass : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --sp protonpass
	assert_success
	run yq -r '.proton_pass_token' "$SCT_HOME_DIR/settings.json"
	assert_output ""
}

@test "init adds proton_pass_token when protonpass selected" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider protonpass : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider protonpass
	assert_success
	run yq -r '.proton_pass_token' "$SCT_HOME_DIR/settings.json"
	assert_output ""
}

@test "init summary for protonpass shows pat create and pat access grant guidance" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider protonpass : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider protonpass
	assert_success
	assert_output --partial "pass-cli pat create"
	assert_output --partial "pat access grant"
}

@test "init accepts valid --stacks value" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path $PROJECT_DIR --agent claude --ide vscode --name test --stacks 'python rust' --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "python,rust" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init rejects invalid --stacks value" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "python,invalid" --features "" --secret-provider none
	assert_failure
	assert_output --partial "Invalid stack: invalid"
}

@test "init resolves scala dependency to java" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path $PROJECT_DIR --agent claude --ide vscode --name test --stacks 'java scala' --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "scala" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init pre-selects 1password provider when op token exists" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	# Create user settings with a non-empty op token
	echo '{"op_service_account_token": "ops_test123"}' > "$SCT_HOME_DIR/settings.json"

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude cursor : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' 1password none protonpass : echo 1password"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' : echo ''" \
		"'Select development stacks (comma-separated numbers, empty for none):' node python java rust go scala ruby dotnet zig : echo ''"

	local expected_name
	expected_name=$(basename "$PROJECT_DIR")-sandbox
	local settings_file=".sandcat/settings.json"

	stub settings "$PROJECT_DIR/$settings_file claude vscode : :"
	stub devcontainer \
		"--settings-file $settings_file --project-path $PROJECT_DIR --agent claude --ide vscode --name $expected_name --stacks '' --proxy web --secret-provider 1password : :"

	run init --path "$PROJECT_DIR"

	assert_success
}

@test "init pre-creates host paths for claude config mount" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	# Directories pre-created so Docker won't materialise them as root-owned
	[[ -d "$HOME/.claude/agents" ]]
	[[ -d "$HOME/.claude/commands" ]]
	[[ -f "$HOME/.claude/CLAUDE.md" ]]
}

@test "init pre-creates host paths for cursor config mount" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json cursor vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent cursor --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent cursor --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	[[ -d "$HOME/.cursor/rules" ]]
	[[ -d "$HOME/.cursor/skills" ]]
	[[ -f "$HOME/.cursor/AGENTS.md" ]]
}

@test "init skips host pre-creation when SANDCAT_MOUNT_CURSOR_CONFIG=false" {
	export SANDCAT_MOUNT_CURSOR_CONFIG=false

	stub settings "$PROJECT_DIR/.sandcat/settings.json cursor vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent cursor --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent cursor --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	[[ ! -d "$HOME/.cursor/rules" ]]
	[[ ! -e "$HOME/.cursor/AGENTS.md" ]]
}

@test "init --netbird passes netbird flag to devcontainer" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server cloud
	assert_success
}

@test "init --netbird seeds netbird_enrollment_key in user settings" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer ":"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server cloud
	assert_success
	run yq '.netbird_enrollment_key' "$SCT_HOME_DIR/settings.json"
	assert_output '""'
	run yq '.netbird_api_token' "$SCT_HOME_DIR/settings.json"
	assert_output '""'
	run yq '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output '""'
}

@test "init rejects --netbird-server without --netbird" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird-server cloud
	assert_failure
	assert_output --partial "--netbird-server requires --netbird"
}

@test "init rejects invalid --netbird-server value" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server invalid
	assert_failure
	assert_output --partial "Invalid NetBird server mode: invalid"
}

@test "init --netbird-server URL persists management server immediately" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url https://management.example.com --netbird : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server https://management.example.com
	assert_success
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "https://management.example.com"
}

@test "init forwards selected netbird management URL to devcontainer args" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url https://selected.example.com --netbird : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server https://selected.example.com
	assert_success
}

@test "init --netbird-server cloud uses cloud summary and clears management URL" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server cloud
	assert_success
	assert_output --partial "Management server: cloud (https://api.netbird.io)"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output ""
}

@test "init --netbird-server new provisions template and uses default URL" {
	unset -f provision_netbird_server_template
	unset -f read_line

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url http://localhost:33073 --netbird : :"
	stub provision_netbird_server_template ":"
	read_line() {
		echo "read_line should not be called for --netbird-server new" >&2
		return 88
	}
	export -f read_line

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server new
	assert_success
	assert_output --partial "Management server: http://localhost:33073"
	assert_output --partial "Self-hosted server template: ~/.config/sandcat/netbird-server/"
	assert_output --partial "Start it:  docker compose -f ~/.config/sandcat/netbird-server/docker-compose.yml up -d"
	assert_output --partial "(Future:   sandcat netbird server start)"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "http://localhost:33073"
}

@test "init interactive netbird server existing re-prompts for non-empty URL" {
	unset -f read_line

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url https://management.example.com --netbird : :"
	stub read_line \
		"'>' : echo '2'" \
		"'Management URL:' : echo ''" \
		"'Management URL:' : echo 'https://management.example.com'"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	assert_output --partial "URL is required"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "https://management.example.com"
}

@test "init interactive netbird existing accepts non-empty URL without format restriction" {
	unset -f read_line

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url management.example.com --netbird : :"
	stub read_line \
		"'>' : echo existing" \
		"'Management URL:' : echo 'management.example.com'"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "management.example.com"
}

@test "init interactive netbird server new provisions template and uses default URL" {
	unset -f read_line
	unset -f provision_netbird_server_template

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url http://localhost:33073 --netbird : :"
	stub provision_netbird_server_template ":"
	stub read_line \
		"'>' : echo 3" \
		"'Management URL [http://localhost:33073]:' : echo ''"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	assert_output --partial "NetBird management server [cloud]:"
	assert_output --partial "1) cloud (api.netbird.io)"
	assert_output --partial "2) self-hosted — I have a server running"
	assert_output --partial "3) self-hosted — provision a new server from template"
	assert_output --partial "Self-hosted server template: ~/.config/sandcat/netbird-server/"
	assert_output --partial "Start it:  docker compose -f ~/.config/sandcat/netbird-server/docker-compose.yml up -d"
	assert_output --partial "(Future:   sandcat netbird server start)"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "http://localhost:33073"
}

@test "init interactive flow (devcontainer mode)" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude cursor : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' none 1password protonpass : echo none"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' : echo ''" \
		"'Select development stacks (comma-separated numbers, empty for none):' node python java rust go scala ruby dotnet zig : echo ''"

	local expected_name
	expected_name=$(basename "$PROJECT_DIR")-sandbox
	local settings_file=".sandcat/settings.json"

	stub settings "$PROJECT_DIR/$settings_file claude vscode : :"
	stub devcontainer \
		"--settings-file $settings_file --project-path $PROJECT_DIR --agent claude --ide vscode --name $expected_name --stacks '' --proxy web --secret-provider none : :"

	run init --path "$PROJECT_DIR"

	assert_success
}
