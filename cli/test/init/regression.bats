#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# This is a regression test verifying that docker-compose configuration is generated correctly.

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/$SCT_PROJECT_DIR"

	SETTINGS_FILE="$SCT_PROJECT_DIR/settings.json"
	touch "$PROJECT_DIR/$SETTINGS_FILE"
}

teardown() {
	unstub_all
}

assert_proxy_service() {
	local compose_file=$1

	yq -e '.services.mitmproxy.image == "mitmproxy/mitmproxy:latest"' "$compose_file"

	# FIXME vscode startup fails with capabilities dropped
	# yq -e '.services.mitmproxy.cap_drop[] | select(. == "ALL")' "$compose_file"
}

assert_agent_service() {
	local compose_file=$1

	yq -e '.services.agent.working_dir == "/workspaces/project-sandbox"' "$compose_file"

	yq -e '.services.agent.network_mode == "service:wg-client"' "$compose_file"

	# FIXME vscode startup fails with capabilities dropped
	# yq -e '.services.agent.cap_drop[] | select(. == "ALL")' "$compose_file"
}

assert_claude_environment_vars() {
	local compose_file=$1

	yq -e '.services.agent.environment.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC == 1' "$compose_file"
}

assert_cursor_environment_vars() {
	local compose_file=$1

	# Cursor template must omit `environment:` entirely when there are no
	# compose-level env vars. `environment: {}` breaks compose validation.
	yq -e '.services.agent | has("environment") | not' "$compose_file"
}

assert_common_volumes() {
	local compose_file=$1

	# Bind: Project root
	PROJECT_DIR="$PROJECT_DIR" yq -e '
		.services.agent.volumes[] |
		select(.type == "bind" and .source == env(PROJECT_DIR) and .target == "/workspaces/project-sandbox")
	' "$compose_file"

	# Bind: .sandcat (read-only)
	PROJECT_DIR="$PROJECT_DIR" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(PROJECT_DIR) + \"/.sandcat\") and
			.target == \"/workspaces/project-sandbox/.sandcat\" and
			.read_only == true
		)
	" "$compose_file"

	# Volume: agent-home
	yq -e '
		.services.agent.volumes[] |
		select(.type == "volume" and .source == "agent-home" and .target == "/home/vscode")
	' "$compose_file"

	# Volume: mitmproxy-config (read-only)
	yq -e '
		.services.agent.volumes[] |
		select(.type == "volume" and .source == "mitmproxy-config" and .target == "/mitmproxy-config" and .read_only == true)
	' "$compose_file"
}

assert_named_volumes() {
	local compose_file=$1
	shift
	local volume_names=("$@")

	for volume_name in "${volume_names[@]}"
	do
		volume_name="$volume_name" yq -e '.volumes | select(has(env(volume_name)))' "$compose_file"
	done
}

assert_claude_volumes() {
	local compose_file=$1

	# Bind: CLAUDE.md (read-only)
	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.claude/CLAUDE.md\") and
			.target == \"/home/vscode/.claude/CLAUDE.md\" and
			.read_only == true
		)
	" "$compose_file"

	# Bind: agents (read-only)
	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.claude/agents\") and
			.target == \"/home/vscode/.claude/agents\" and
			.read_only == true
		)
	" "$compose_file"

	# Bind: commands (read-only)
	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.claude/commands\") and
			.target == \"/home/vscode/.claude/commands\" and
			.read_only == true
		)
	" "$compose_file"
}

# Mitmproxy project settings mount + optional .git — used for all IDE/agent combos when enabled.
assert_customization_volumes_core() {
	local compose_file=$1

	# Bind: settings directory (read-only)
	PROJECT_DIR="$PROJECT_DIR" yq -e "
		.services.mitmproxy.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(PROJECT_DIR) + \"/.sandcat\") and
			.target == \"/config/project\" and
			.read_only == true
		)
	" "$compose_file"

	# Bind: .git (read-only)
	PROJECT_DIR="$PROJECT_DIR" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(PROJECT_DIR) + \"/.git\") and
			.target == \"/workspace/.git\" and
			.read_only == true
		)
	" "$compose_file"
}

# Active .idea bind mount — only when JetBrains IDE (or explicit SANDCAT_MOUNT_IDEA_READONLY=true).
assert_customization_volumes_idea() {
	local compose_file=$1

	PROJECT_DIR="$PROJECT_DIR" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(PROJECT_DIR) + \"/.idea\") and
			.target == \"/workspace/.idea\" and
			.read_only == true
		)
	" "$compose_file"
}

assert_customization_volumes() {
	local compose_file=$1

	assert_customization_volumes_core "$compose_file"
	assert_customization_volumes_idea "$compose_file"
}

assert_cursor_volumes() {
	local compose_file=$1

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/AGENTS.md\") and
			.target == \"/home/vscode/.cursor/AGENTS.md\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/rules\") and
			.target == \"/home/vscode/.cursor/rules\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/skills\") and
			.target == \"/home/vscode/.cursor/skills\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/commands\") and
			.target == \"/home/vscode/.cursor/commands\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/agents\") and
			.target == \"/home/vscode/.cursor/agents\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/hooks\") and
			.target == \"/home/vscode/.cursor/hooks\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/hooks.json\") and
			.target == \"/home/vscode/.cursor/hooks.json\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/mcp.json\") and
			.target == \"/home/vscode/.cursor/mcp.json\" and
			.read_only == true
		)
	" "$compose_file"

	HOME="$HOME" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(HOME) + \"/.cursor/projects/workspaces-project-sandbox\") and
			.target == \"/home/vscode/.cursor/projects/workspaces-project-sandbox\" and
			(.read_only // false) == false
		)
	" "$compose_file"
}

assert_devcontainer_volume() {
	local compose_file=$1

	# Bind: .devcontainer (read-only)
	PROJECT_DIR="$PROJECT_DIR" yq -e "
		.services.agent.volumes[] |
		select(
			.type == \"bind\" and
			.source == (env(PROJECT_DIR) + \"/.devcontainer\") and
			.target == \"/workspaces/project-sandbox/.devcontainer\" and
			.read_only == true
		)
	" "$compose_file"
}

assert_jetbrains_capabilities() {
	local compose_file=$1

	yq -e '.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "CHOWN")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "FOWNER")' "$compose_file"
}

claude_agent_compose_file_has_expected_content() {
	local compose_file=$1

	assert_proxy_service "$compose_file"
	assert_agent_service "$compose_file"
	assert_claude_environment_vars "$compose_file"
	assert_common_volumes "$compose_file"

	assert_named_volumes "$compose_file" "agent-home" "mitmproxy-config"
	assert_claude_volumes "$compose_file"
	assert_customization_volumes "$compose_file"
}

cursor_agent_compose_file_has_expected_content() {
	local compose_file=$1

	assert_proxy_service "$compose_file"
	assert_agent_service "$compose_file"
	assert_cursor_environment_vars "$compose_file"
	assert_common_volumes "$compose_file"

	assert_named_volumes "$compose_file" "agent-home" "mitmproxy-config"
	assert_cursor_volumes "$compose_file"
	# Cursor regression uses --ide vscode and SANDCAT_MOUNT_IDEA_READONLY=false — no active .idea mount.
	assert_customization_volumes_core "$compose_file"
}

@test "devcontainer end-to-end: creates devcontainer config for claude agent" {
	export SANDCAT_MOUNT_CLAUDE_CONFIG="true"
	export SANDCAT_ENABLE_DOTFILES="true"
	export SANDCAT_MOUNT_GIT_READONLY="true"
	export SANDCAT_MOUNT_IDEA_READONLY="true"

	run devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent "claude" \
		--ide "jetbrains"
	assert_success
	assert_output --partial "Devcontainer dir created at .devcontainer"

	# Use docker compose config to get the effective merged configuration
	local effective_file="$BATS_TEST_TMPDIR/effective-compose.yml"
	docker compose -f "$PROJECT_DIR/.devcontainer/compose-all.yml" config > "$effective_file"

	yq -e '.name == "project-sandbox"' "$effective_file"

	claude_agent_compose_file_has_expected_content "$effective_file"

	assert_devcontainer_volume "$effective_file"
	assert_jetbrains_capabilities "$effective_file"
}

@test "devcontainer end-to-end: creates devcontainer config for cursor agent" {
	export SANDCAT_MOUNT_CURSOR_CONFIG="true"
	export SANDCAT_ENABLE_DOTFILES="true"
	export SANDCAT_MOUNT_GIT_READONLY="true"
	export SANDCAT_MOUNT_IDEA_READONLY="false"

	run devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent "cursor" \
		--ide "vscode"
	assert_success
	assert_output --partial "Devcontainer dir created at .devcontainer"

	local effective_file="$BATS_TEST_TMPDIR/effective-compose-cursor.yml"
	docker compose -f "$PROJECT_DIR/.devcontainer/compose-all.yml" config > "$effective_file"

	yq -e '.name == "project-sandbox"' "$effective_file"

	cursor_agent_compose_file_has_expected_content "$effective_file"
	assert_devcontainer_volume "$effective_file"
}
