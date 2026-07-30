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
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' : echo ''" \
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
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' : echo ''" \
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
}

@test "init interactive feature selection applies tui from full labels" {
	unset -f read_line
	unset -f select_option
	unset -f select_multiple

	stub read_line "* : echo ''"
	stub select_option \
		"'Select agent:' claude cursor : echo claude" \
		"'Select IDE:' vscode jetbrains none : echo vscode" \
		"'Select secret provider:' none 1password protonpass : echo none"
	stub select_multiple \
		"'Select optional features (comma-separated numbers, empty for none):' 'tui (mitmproxy console instead of web UI)' 'no-shared-cache (per-project dep cache instead of shared)' 'no-gitignore (do not append Sandcat block to .gitignore)' : echo 'tui (mitmproxy console instead of web UI)'" \
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
