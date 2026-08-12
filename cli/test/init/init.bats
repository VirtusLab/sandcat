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

@test "init accepts codex as valid --agent value" {
	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init accepts copilot as valid --agent value" {
	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json copilot vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent copilot --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent copilot --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
}

@test "user_settings_template_path returns copilot template for copilot" {
	run user_settings_template_path copilot
	assert_success
	assert_output --partial "settings-user-copilot.json"
}

@test "init creates user settings with COPILOT_GITHUB_TOKEN when agent=copilot" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json copilot vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent copilot --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent copilot --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	run yq -r '.secrets.COPILOT_GITHUB_TOKEN.value' "$SCT_HOME_DIR/settings.json"
	assert_output ""

	run yq -r '.secrets.COPILOT_GITHUB_TOKEN.hosts | .[0]' "$SCT_HOME_DIR/settings.json"
	assert_output "api.github.com"

	run yq -r '.network | map(.host) | index("*.githubcopilot.com")' "$SCT_HOME_DIR/settings.json"
	refute_output "null"
}

@test "init pre-creates host paths for codex config mount" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	# Directories/files pre-created so Docker won't materialise them as root-owned.
	[[ -d "$HOME/.codex/skills" ]]
	[[ -d "$HOME/.codex/commands" ]]
	[[ -f "$HOME/.codex/AGENTS.md" ]]
}

@test "init skips host pre-creation when SANDCAT_MOUNT_CODEX_CONFIG=false" {
	export SANDCAT_MOUNT_CODEX_CONFIG=false

	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	[[ ! -d "$HOME/.codex" ]]
}

@test "init summary for codex mentions OPENAI_API_KEY" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "Codex CLI"
}

@test "init seeds OPENAI_API_KEY into existing user settings when agent=codex" {
	# Seed a pre-existing settings.json with only a GITHUB_TOKEN (simulating
	# a user who ran init with --agent claude/cursor previously).
	mkdir -p "$SCT_HOME_DIR"
	cat > "$SCT_HOME_DIR/settings.json" <<'EOF'
{
    "env": {},
    "secrets": {
        "GITHUB_TOKEN": {"value": "", "hosts": ["github.com"]}
    },
    "network": [
        {"action": "allow", "host": "github.com"}
    ]
}
EOF

	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	# Verify OPENAI_API_KEY seeded
	run yq -r '.secrets.OPENAI_API_KEY.value' "$SCT_HOME_DIR/settings.json"
	assert_output ""    # empty string is the seeded placeholder

	run yq -r '.secrets.OPENAI_API_KEY.hosts | .[0]' "$SCT_HOME_DIR/settings.json"
	assert_output "api.openai.com"

	# Existing GITHUB_TOKEN preserved
	run yq -r '.secrets.GITHUB_TOKEN.hosts | .[0]' "$SCT_HOME_DIR/settings.json"
	assert_output "github.com"

	# api.openai.com added to network allowlist
	run yq -r '.network | map(.host) | index("api.openai.com")' "$SCT_HOME_DIR/settings.json"
	refute_output "null"
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
		"'Select agent:' claude cursor codex copilot : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' 1password none protonpass : echo 1password"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' 'no-rtk (do not install rtk shell hook)' 'strict-network (stack presets instead of allow-all-GET wildcard)' : echo ''" \
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
	[[ -d "$HOME/.cursor/commands" ]]
	[[ -d "$HOME/.cursor/agents" ]]
	[[ -d "$HOME/.cursor/hooks" ]]
	[[ -d "$HOME/.cursor/projects/workspaces-test" ]]
	[[ -f "$HOME/.cursor/AGENTS.md" ]]
	[[ -f "$HOME/.cursor/hooks.json" ]]
	[[ -f "$HOME/.cursor/mcp.json" ]]
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
	[[ ! -d "$HOME/.cursor/commands" ]]
	[[ ! -d "$HOME/.cursor/agents" ]]
	[[ ! -d "$HOME/.cursor/hooks" ]]
	[[ ! -e "$HOME/.cursor/hooks.json" ]]
	[[ ! -d "$HOME/.cursor/projects" ]]
	[[ ! -d "$HOME/.cursor/chats" ]]
	[[ ! -e "$HOME/.cursor/mcp.json" ]]
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

@test "init --netbird-server new provisions local template and uses default URL" {
	unset -f read_line
	unset -f provision_netbird_server_template

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
	assert_output --partial "Local template: ~/.config/sandcat/netbird-server/"
	assert_output --partial "sandcat netbird server start"
	assert_output --partial "http://localhost:8080"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "http://localhost:33073"
}

@test "init --netbird-server quickstart prints install hint without provisioning" {
	unset -f read_line
	unset -f provision_netbird_server_template

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird : :"
	provision_netbird_server_template() {
		echo "provision_netbird_server_template should not be called for quickstart" >&2
		return 88
	}
	export -f provision_netbird_server_template

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird --netbird-server quickstart
	assert_success
	assert_output --partial "getting-started.sh"
	assert_output --partial "selfhosted-quickstart"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output ""
}

@test "init interactive netbird server new provisions local template" {
	unset -f read_line
	unset -f provision_netbird_server_template
	unset -f netbird_detect_docker_host_ip

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url http://localhost:33073 --netbird : :"
	stub provision_netbird_server_template ":"
	stub netbird_detect_docker_host_ip "echo 192.168.1.50"
	stub read_line \
		"'>' : echo 3" \
		"'Management URL [http://localhost:33073]:' : echo ''" \
		"'Enrollment URL [http://192.168.1.50:33073]:' : echo ''"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	assert_output --partial "3) self-hosted — local template (localhost)"
	assert_output --partial "Local template: ~/.config/sandcat/netbird-server/"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "http://localhost:33073"
}

@test "init interactive netbird server new persists container-reachable enrollment URL" {
	unset -f read_line
	unset -f provision_netbird_server_template
	unset -f netbird_detect_docker_host_ip

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url http://localhost:33073 --netbird : :"
	stub provision_netbird_server_template ":"
	stub netbird_detect_docker_host_ip "echo 192.168.1.50"
	stub read_line \
		"'>' : echo 3" \
		"'Management URL [http://localhost:33073]:' : echo ''" \
		"'Enrollment URL [http://192.168.1.50:33073]:' : echo ''"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	# localhost resolves to the container itself; without this setting
	# enable_netbird emits no NB_MANAGEMENT_URL and netbird enrolls against cloud.
	run yq -r '.netbird_enrollment_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "http://192.168.1.50:33073"
}

@test "init interactive netbird quickstart prints install hint and accepts URL" {
	unset -f read_line
	unset -f provision_netbird_server_template

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url https://netbird.example.com --netbird : :"
	stub read_line \
		"'>' : echo 4" \
		"'Management URL (e.g. https://netbird.example.com):' : echo 'https://netbird.example.com'"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	assert_output --partial "4) self-hosted — NetBird quickstart (VM + domain)"
	assert_output --partial "getting-started.sh"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "https://netbird.example.com"
}

@test "init interactive netbird quickstart re-prompts for non-empty URL" {
	unset -f read_line

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird-management-url https://netbird.example.com --netbird : :"
	stub read_line \
		"'>' : echo 4" \
		"'Management URL (e.g. https://netbird.example.com):' : echo ''" \
		"'Management URL (e.g. https://netbird.example.com):' : echo 'https://netbird.example.com'"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none --netbird
	assert_success
	# An empty URL would silently enroll a self-hosted key against NetBird cloud.
	assert_output --partial "URL is required for a self-hosted quickstart server"
	run yq -r '.netbird_management_url' "$SCT_HOME_DIR/settings.json"
	assert_output "https://netbird.example.com"
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

@test "init interactive flow (devcontainer mode)" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude cursor codex copilot : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' none 1password protonpass : echo none"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' 'no-rtk (do not install rtk shell hook)' 'strict-network (stack presets instead of allow-all-GET wildcard)' : echo ''" \
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

@test "init summary always mentions devbox" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
	assert_output --partial "Devbox tools:"
	assert_output --partial "Devbox stack:"
}

@test "init --features tui applies the tui feature" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy tui --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "tui" --secret-provider none
	assert_success
}

@test "init --features no-shared-cache exports SANDCAT_MOUNT_SHARED_CACHE=false" {
	# The devcontainer stub echoes the env var so we can assert it
	# propagated across the sub-command boundary via `export`.
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"SHARED=\$SANDCAT_MOUNT_SHARED_CACHE\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-shared-cache" --secret-provider none
	assert_success
	assert_output --partial "SHARED=false"
}

@test "init --features tui,no-shared-cache accepts both" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy tui --secret-provider none : echo \"SHARED=\$SANDCAT_MOUNT_SHARED_CACHE\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "tui,no-shared-cache" --secret-provider none
	assert_success
	assert_output --partial "SHARED=false"
}

@test "init rejects unknown feature and lists all supported ones" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "bogus" --secret-provider none
	assert_failure
	assert_output --partial "Unknown feature: bogus"
	assert_output --partial "tui"
	assert_output --partial "no-shared-cache"
	assert_output --partial "no-gitignore"
	assert_output --partial "no-rtk"
}

@test "init interactive feature selection applies tui from full labels" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude cursor codex copilot : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' none 1password protonpass : echo none"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' 'no-rtk (do not install rtk shell hook)' 'strict-network (stack presets instead of allow-all-GET wildcard)' : echo 'tui (mitmproxy console instead of web UI)'" \
		"'Select development stacks (comma-separated numbers, empty for none):' node python java rust go scala ruby dotnet zig : echo ''"

	local expected_name
	expected_name=$(basename "$PROJECT_DIR")-sandbox
	local settings_file=".sandcat/settings.json"

	stub settings "$PROJECT_DIR/$settings_file claude vscode : :"
	stub devcontainer \
		"--settings-file $settings_file --project-path $PROJECT_DIR --agent claude --ide vscode --name $expected_name --stacks '' --proxy tui --secret-provider none : :"

	run init --path "$PROJECT_DIR"
	assert_success
}

@test "init appends Sandcat gitignore block when the project is a git repo" {
	mkdir -p "$PROJECT_DIR/.git"
	printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        added Sandcat block"

	# Existing content preserved, sandcat block appended.
	grep -qxF "node_modules/" "$PROJECT_DIR/.gitignore"
	grep -qxF "# Sandcat" "$PROJECT_DIR/.gitignore"
	grep -qxF ".devcontainer/*" "$PROJECT_DIR/.gitignore"
	grep -qxF "!.devcontainer/devbox.tools.json" "$PROJECT_DIR/.gitignore"
	grep -qxF ".sandcat/settings.local.json" "$PROJECT_DIR/.gitignore"
}

@test "init gitignore append is idempotent across re-init" {
	mkdir -p "$PROJECT_DIR/.git"

	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :" \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :" \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none >/dev/null
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        Sandcat block already present"

	# Exactly one Sandcat block — no duplication.
	local count
	count=$(grep -c '^# Sandcat$' "$PROJECT_DIR/.gitignore")
	[ "$count" = "1" ]
}

@test "init skips gitignore when project is not a git repo" {
	# No .git directory intentionally.
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        skipped (no .git in project)"
	[ ! -f "$PROJECT_DIR/.gitignore" ]
}

@test "init --features no-gitignore skips gitignore even in a git repo" {
	mkdir -p "$PROJECT_DIR/.git"

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-gitignore" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        skipped (disabled)"
	[ ! -f "$PROJECT_DIR/.gitignore" ]
}

@test "init respects SANDCAT_GITIGNORE=false env var" {
	mkdir -p "$PROJECT_DIR/.git"

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	SANDCAT_GITIGNORE=false run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        skipped (disabled)"
	[ ! -f "$PROJECT_DIR/.gitignore" ]
}

@test "init lists no-gitignore in unknown-feature error message" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "bogus" --secret-provider none
	assert_failure
	assert_output --partial "Unknown feature: bogus"
	assert_output --partial "tui"
	assert_output --partial "no-gitignore"
}

@test "init --features no-gitignore removes previously-added Sandcat block (symmetric)" {
	mkdir -p "$PROJECT_DIR/.git"
	printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"

	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :" \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :" \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	# First init adds block.
	init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none >/dev/null
	grep -qxF "# Sandcat" "$PROJECT_DIR/.gitignore"
	grep -qxF "# /Sandcat" "$PROJECT_DIR/.gitignore"

	# Second init with no-gitignore removes the block.
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-gitignore" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        removed Sandcat block (disabled)"

	# User rules preserved, sandcat block gone.
	grep -qxF "node_modules/" "$PROJECT_DIR/.gitignore"
	grep -qxF "*.log" "$PROJECT_DIR/.gitignore"
	run grep -c "^# Sandcat" "$PROJECT_DIR/.gitignore"
	assert_output "0"
}

@test "init --features no-gitignore removes block via SANDCAT_GITIGNORE=false env" {
	mkdir -p "$PROJECT_DIR/.git"

	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :" \
		"$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :" \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none >/dev/null

	# Env-var opt-out also removes.
	SANDCAT_GITIGNORE=false run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        removed Sandcat block (disabled)"
	[ ! -f "$PROJECT_DIR/.gitignore" ] || ! grep -q "^# Sandcat" "$PROJECT_DIR/.gitignore"
}

@test "init --features no-gitignore is a no-op when there was no block" {
	mkdir -p "$PROJECT_DIR/.git"
	printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-gitignore" --secret-provider none
	assert_success
	assert_output --partial "Gitignore:        skipped (disabled)"
	# User's .gitignore stays as-is.
	run cat "$PROJECT_DIR/.gitignore"
	assert_output "node_modules/"
}

@test "init append is byte-exact — no stranded blank line before Sandcat block" {
	mkdir -p "$PROJECT_DIR/.git"
	# File ending with \n — bash command substitution strips trailing
	# newlines, so a naive check would falsely think the file doesn't
	# end with one and add an extra newline.
	printf 'a\nb\n' > "$PROJECT_DIR/.gitignore"

	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none >/dev/null

	# Expect exactly one blank line between "b" and "# Sandcat".
	local expected_lines
	expected_lines=$(awk 'NR==1 { r1=$0 } NR==2 { r2=$0 } NR==3 { r3=$0 } NR==4 { r4=$0 } END { print r1"|"r2"|"r3"|"r4 }' "$PROJECT_DIR/.gitignore")
	[ "$expected_lines" = "a|b||# Sandcat" ]
}

@test "init --features no-rtk exports SANDCAT_RTK=false" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-rtk" --secret-provider none
	assert_success
	assert_output --partial "RTK=false"
}

@test "init respects SANDCAT_RTK=false env var" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	SANDCAT_RTK=false run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK=false"
}

@test "init default exports SANDCAT_RTK=true" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK=true"
}

@test "init summary reports rtk status" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	# default → installed
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK:              installed"
}

@test "init --features no-rtk reports rtk disabled" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-rtk" --secret-provider none
	assert_success
	assert_output --partial "RTK:              disabled"
}

@test "init rejects bogus feature and lists no-rtk in expected values" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "bogus" --secret-provider none
	assert_failure
	assert_output --partial "no-rtk"
	assert_output --partial "strict-network"
}

@test "init --features strict-network passes strict flags with resolved stacks to settings" {
	stub settings \
		"--strict-network --stacks python $PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "python" --features "strict-network" --secret-provider none
	assert_success
	assert_output --partial "Network:          strict — stack presets: python"
}

@test "init without strict-network reports the default network policy" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "Network:          default (allow all GET"
}
