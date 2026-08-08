#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# Direct unit tests for the sct_agent_* dispatcher contract in
# cli/lib/agents.bash. These tests lock the shape of the dispatch table —
# the next agent integration must add a case branch here without changing
# existing behaviour.
#
# Each test exercises three inputs:
#   - claude    — primary supported agent
#   - cursor    — second supported agent (added in the Cursor PR)
#   - unknown   — unsupported value, exercising the `*` fallback

setup() {
	load test_helper
	# shellcheck source=../../lib/agents.bash
	source "$SCT_LIBDIR/agents.bash"
}

# ---------------------------------------------------------------- discovery

@test "sct_available_agents lists claude, cursor and codex" {
	run sct_available_agents
	assert_success
	assert_output "claude cursor codex"
}

@test "sct_is_valid_agent accepts known agents" {
	run sct_is_valid_agent claude
	assert_success
	run sct_is_valid_agent cursor
	assert_success
}

@test "sct_is_valid_agent accepts codex" {
	run sct_is_valid_agent codex
	assert_success
}

@test "sct_is_valid_agent rejects unknown agent" {
	run sct_is_valid_agent unknown
	assert_failure
}

# ----------------------------------------------------- mount env var dispatch

@test "sct_agent_mount_env_var: claude" {
	run sct_agent_mount_env_var claude
	assert_output "SANDCAT_MOUNT_CLAUDE_CONFIG"
}

@test "sct_agent_mount_env_var: cursor" {
	run sct_agent_mount_env_var cursor
	assert_output "SANDCAT_MOUNT_CURSOR_CONFIG"
}

@test "sct_agent_mount_env_var: codex" {
	run sct_agent_mount_env_var codex
	assert_output "SANDCAT_MOUNT_CODEX_CONFIG"
}

@test "sct_agent_mount_env_var: unknown returns empty" {
	run sct_agent_mount_env_var unknown
	assert_output ""
}

# ---------------------------------------------------- host config path lists

@test "sct_agent_host_config_paths: claude lists ~/.claude entries" {
	run sct_agent_host_config_paths claude
	assert_output --partial '$HOME/.claude/agents/'
	assert_output --partial '$HOME/.claude/commands/'
	assert_output --partial '$HOME/.claude/CLAUDE.md'
}

@test "sct_cursor_workspace_project_id: encodes /workspaces/<name>" {
	run sct_cursor_workspace_project_id "foo-bar"
	assert_output "workspaces-foo-bar"

	run sct_cursor_workspace_project_id "project-sandbox"
	assert_output "workspaces-project-sandbox"
}

@test "sct_agent_host_config_paths: cursor lists ~/.cursor entries" {
	run sct_agent_host_config_paths cursor "test-project"
	assert_output --partial '$HOME/.cursor/rules/'
	assert_output --partial '$HOME/.cursor/skills/'
	assert_output --partial '$HOME/.cursor/commands/'
	assert_output --partial '$HOME/.cursor/agents/'
	assert_output --partial '$HOME/.cursor/hooks/'
	assert_output --partial '$HOME/.cursor/projects/workspaces-test-project/'
	assert_output --partial '$HOME/.cursor/AGENTS.md'
	assert_output --partial '$HOME/.cursor/hooks.json'
	assert_output --partial '$HOME/.cursor/mcp.json'
	refute_output --partial '$HOME/.cursor/chats/'
	refute_output --partial '$HOME/.cursor/plugins/'
	refute_output --partial '$HOME/.cursor/subagents/'
}

@test "sct_agent_host_config_paths: codex lists ~/.codex entries" {
	run sct_agent_host_config_paths codex
	assert_output --partial '$HOME/.codex/AGENTS.md'
	assert_output --partial '$HOME/.codex/skills/'
	assert_output --partial '$HOME/.codex/commands/'
	refute_output --partial '$HOME/.codex/config.toml'
	refute_output --partial '$HOME/.codex/.credentials.json'
}

@test "sct_agent_host_config_paths: unknown returns empty" {
	run sct_agent_host_config_paths unknown
	assert_output ""
}

# ---------------------------------------------- ensure_host_agent_config_paths

@test "ensure_host_agent_config_paths: creates claude paths under HOME" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	run ensure_host_agent_config_paths claude
	assert_success

	[[ -d "$HOME/.claude/agents" ]]
	[[ -d "$HOME/.claude/commands" ]]
	[[ -f "$HOME/.claude/CLAUDE.md" ]]
}

@test "ensure_host_agent_config_paths: skips when SANDCAT_MOUNT_CLAUDE_CONFIG=false" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	export SANDCAT_MOUNT_CLAUDE_CONFIG=false

	run ensure_host_agent_config_paths claude
	assert_success

	[[ ! -d "$HOME/.claude" ]]
}

@test "ensure_host_agent_config_paths: creates cursor paths under HOME" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	run ensure_host_agent_config_paths cursor test
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
	assert_equal "$(<"$HOME/.cursor/hooks.json")" '{"hooks":{}}'
	assert_equal "$(<"$HOME/.cursor/mcp.json")" '{"mcpServers":{}}'
}

@test "ensure_host_agent_config_paths: seeds empty JSON files but preserves existing content" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.cursor"
	printf '%s\n' '{"hooks":{"stop":[{"command":"./hook.sh"}]}}' >"$HOME/.cursor/hooks.json"

	run ensure_host_agent_config_paths cursor test
	assert_success

	assert_equal "$(<"$HOME/.cursor/hooks.json")" '{"hooks":{"stop":[{"command":"./hook.sh"}]}}'
}

@test "ensure_host_agent_config_paths: skips when SANDCAT_MOUNT_CURSOR_CONFIG=false" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	export SANDCAT_MOUNT_CURSOR_CONFIG=false

	run ensure_host_agent_config_paths cursor test
	assert_success

	[[ ! -d "$HOME/.cursor" ]]
}

@test "ensure_host_agent_config_paths: creates codex paths under HOME" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	export SANDCAT_MOUNT_CODEX_CONFIG=true
	ensure_host_agent_config_paths codex

	[[ -d "$HOME/.codex/skills" ]]
	[[ -d "$HOME/.codex/commands" ]]
	[[ -f "$HOME/.codex/AGENTS.md" ]]
}

@test "ensure_host_agent_config_paths: codex opt-out via SANDCAT_MOUNT_CODEX_CONFIG=false" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	export SANDCAT_MOUNT_CODEX_CONFIG=false
	ensure_host_agent_config_paths codex

	# Nothing should have been created on the host.
	[[ ! -d "$HOME/.codex" ]]
}

@test "ensure_host_agent_config_paths: no-op for unknown agent" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	run ensure_host_agent_config_paths unknown
	assert_success
}

# ----------------------------------------------------------- API key help

@test "sct_agent_api_key_help: claude" {
	run sct_agent_api_key_help claude
	assert_output --partial "ANTHROPIC_API_KEY"
}

@test "sct_agent_api_key_help: cursor" {
	run sct_agent_api_key_help cursor
	assert_output --partial "CURSOR_API_KEY"
}

@test "sct_agent_api_key_help: codex" {
	run sct_agent_api_key_help codex
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "Codex CLI"
}

@test "sct_agent_api_key_help: unknown falls back to anthropic line" {
	run sct_agent_api_key_help unknown
	assert_output --partial "ANTHROPIC_API_KEY"
}

@test "sct_agent_op_api_key_help: claude" {
	run sct_agent_op_api_key_help claude
	assert_output --partial "ANTHROPIC_API_KEY"
	assert_output --partial 'op://vault/Anthropic API Key/credential'
}

@test "sct_agent_op_api_key_help: cursor" {
	run sct_agent_op_api_key_help cursor
	assert_output --partial "CURSOR_API_KEY"
	assert_output --partial 'op://vault/Cursor API Key/credential'
}

@test "sct_agent_op_api_key_help: codex" {
	run sct_agent_op_api_key_help codex
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "op://vault/OpenAI API Key/credential"
}

@test "sct_agent_op_api_key_help: unknown falls back to anthropic line" {
	run sct_agent_op_api_key_help unknown
	assert_output --partial "ANTHROPIC_API_KEY"
	assert_output --partial 'op://vault/Anthropic API Key/credential'
}

# --------------------------------------------------------- VS Code extension

@test "sct_agent_vscode_extension: claude" {
	run sct_agent_vscode_extension claude
	assert_output "anthropic.claude-code"
}

@test "sct_agent_vscode_extension: cursor" {
	run sct_agent_vscode_extension cursor
	assert_output "anysphere.cursor"
}

@test "sct_agent_vscode_extension: codex" {
	run sct_agent_vscode_extension codex
	assert_output "openai.chatgpt"
}

@test "sct_agent_vscode_extension: unknown returns empty" {
	run sct_agent_vscode_extension unknown
	assert_output ""
}

# --------------------------------------------------- devcontainer settings

@test "sct_agent_devcontainer_settings_block: claude includes claudeCode keys" {
	run sct_agent_devcontainer_settings_block claude
	assert_output --partial "claudeCode.allowDangerouslySkipPermissions"
}

@test "sct_agent_devcontainer_settings_block: cursor returns a placeholder note" {
	run sct_agent_devcontainer_settings_block cursor
	# Comment-only block — must not be empty (otherwise apply_template_placeholders
	# will drop the placeholder line entirely, removing JSON context).
	[[ -n "$output" ]]
	assert_output --partial "Cursor"
}

@test "sct_agent_devcontainer_settings_block: codex returns empty" {
	run sct_agent_devcontainer_settings_block codex
	assert_output ""
}

@test "sct_agent_devcontainer_settings_block: unknown returns empty" {
	run sct_agent_devcontainer_settings_block unknown
	assert_output ""
}

# --------------------------------------------------- compose environment

@test "sct_agent_compose_environment_entries: claude has CLAUDE_CODE flag" {
	run sct_agent_compose_environment_entries claude
	assert_output "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
}

@test "sct_agent_compose_environment_entries: cursor returns empty" {
	run sct_agent_compose_environment_entries cursor
	assert_output ""
}

@test "sct_agent_compose_environment_entries: codex returns empty" {
	run sct_agent_compose_environment_entries codex
	assert_output ""
}

@test "sct_agent_compose_environment_entries: unknown returns empty" {
	run sct_agent_compose_environment_entries unknown
	assert_output ""
}

# --------------------------------------------------- Dockerfile install

@test "sct_agent_docker_install_block: claude installs claude binary" {
	run sct_agent_docker_install_block claude
	assert_output --partial "claude.ai/install.sh"
}

@test "sct_agent_docker_install_block: cursor installs cursor cli" {
	run sct_agent_docker_install_block cursor
	assert_output --partial "cursor.com/install"
}

@test "sct_agent_docker_install_block: codex installs codex to /usr/local/bin" {
	unset SANDCAT_RTK
	run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	assert_output --partial "CODEX_INSTALL_DIR=/usr/local/bin"
	assert_output --partial "CODEX_HOME=/opt/codex-home"
	assert_output --partial "USER root"
	assert_output --partial "USER vscode"
	# Env vars must be inline on `sh` (not `ENV`) — otherwise CODEX_HOME
	# would leak to runtime.
	refute_output --partial "ENV CODEX_HOME"
	refute_output --partial "ENV CODEX_INSTALL_DIR"
}

@test "sct_agent_docker_install_block: codex append rtk install when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: codex skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	refute_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: unknown returns empty" {
	run sct_agent_docker_install_block unknown
	assert_output ""
}

@test "sct_agent_docker_install_block: claude append rtk install when enabled" {
	# shellcheck source=../../lib/rtk.bash
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block claude
	assert_output --partial "claude.ai/install.sh"
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: claude skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_docker_install_block claude
	assert_output --partial "claude.ai/install.sh"
	refute_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: unknown returns empty even with rtk enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block unknown
	assert_output ""
}

# --------------------------------------------------- Dockerfile home prep

@test "sct_agent_docker_home_prep_block: claude pre-creates ~/.claude" {
	run sct_agent_docker_home_prep_block claude
	assert_output --partial "/home/vscode/.claude"
}

@test "sct_agent_docker_home_prep_block: cursor pre-creates ~/.cursor" {
	run sct_agent_docker_home_prep_block cursor
	assert_output --partial "/home/vscode/.cursor"
}

@test "sct_agent_docker_home_prep_block: codex pre-creates ~/.codex, ~/.codex-host and codex-yolo alias" {
	run sct_agent_docker_home_prep_block codex
	assert_output --partial "/home/vscode/.codex"
	assert_output --partial "/home/vscode/.codex-host"
	assert_output --partial 'alias codex-yolo="codex --yolo"'
}

@test "sct_agent_docker_home_prep_block: unknown returns empty" {
	run sct_agent_docker_home_prep_block unknown
	assert_output ""
}

# --------------------------------------------------- user init bootstrap

@test "sct_agent_user_init_block: claude seeds onboarding" {
	run sct_agent_user_init_block claude
	assert_output --partial "hasCompletedOnboarding"
}

@test "sct_agent_user_init_block: cursor applies Sandcat cursor.cli fragment" {
	run sct_agent_user_init_block cursor
	assert_output --partial "cursor-cli-config.json"
	assert_output --partial "Sandcat cursor.cli"
}

@test "sct_agent_user_init_block: unknown returns empty" {
	run sct_agent_user_init_block unknown
	assert_output ""
}

@test "sct_agent_user_init_block: claude appends rtk init when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block claude
	assert_output --partial "hasCompletedOnboarding"
	assert_output --partial "rtk init -g"
}

@test "sct_agent_user_init_block: claude skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_user_init_block claude
	assert_output --partial "hasCompletedOnboarding"
	refute_output --partial "rtk init"
}

@test "sct_agent_user_init_block: cursor appends rtk init when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block cursor
	assert_output --partial "cursor-cli-config.json"
	assert_output --partial "rtk init -g --hook-only --auto-patch --agent cursor"
}

@test "sct_agent_user_init_block: cursor skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_user_init_block cursor
	assert_output --partial "cursor-cli-config.json"
	refute_output --partial "rtk init"
}

@test "sct_agent_user_init_block: codex emits rtk init --codex + host AGENTS.md seed" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block codex
	assert_output --partial "codex --version"
	assert_output --partial "rtk init -g --codex"
	assert_output --partial ".codex-host/AGENTS.md"
	assert_output --partial "@RTK.md"
	assert_output --partial "non-fatal"
}

@test "sct_agent_user_init_block: codex has SANDCAT_RTK runtime guard" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block codex
	assert_output --partial 'SANDCAT_RTK:-true'
	assert_output --partial '!= "false"'
}

# --------------------------------------------------- mitm streaming flags

@test "sct_agent_mitm_streaming_flags: cursor returns streaming flags" {
	run sct_agent_mitm_streaming_flags cursor
	assert_output --partial "stream_large_bodies=1m"
	assert_output --partial "connection_strategy=lazy"
	assert_output --partial "anticomp=true"
	assert_output --partial "timeout_read=300"
}

@test "sct_agent_mitm_streaming_flags: claude returns empty" {
	# Empty is intentional: leaving stream_large_bodies unset means mitmproxy
	# buffers <1MB bodies, which is what the addon's body-content leak check
	# relies on.
	run sct_agent_mitm_streaming_flags claude
	assert_output ""
}

@test "sct_agent_mitm_streaming_flags: codex returns empty" {
	run sct_agent_mitm_streaming_flags codex
	assert_output ""
}

@test "sct_agent_mitm_streaming_flags: unknown returns empty" {
	run sct_agent_mitm_streaming_flags unknown
	assert_output ""
}

# --------------------------------------------------- post user-settings hook

@test "sct_agent_post_user_settings_hook: cursor calls ensure_cursor_user_settings_defaults when defined" {
	# Stub the helper to record invocation; the hook must call it for cursor.
	local marker="$BATS_TEST_TMPDIR/cursor-hook"
	# shellcheck disable=SC2317
	ensure_cursor_user_settings_defaults() { touch "$marker"; }
	export -f ensure_cursor_user_settings_defaults

	run sct_agent_post_user_settings_hook cursor
	assert_success
	[[ -f "$marker" ]]
}

@test "sct_agent_post_user_settings_hook: claude is a no-op" {
	# Even if the cursor helper is defined, the claude path must not call it.
	local marker="$BATS_TEST_TMPDIR/cursor-hook"
	# shellcheck disable=SC2317
	ensure_cursor_user_settings_defaults() { touch "$marker"; }
	export -f ensure_cursor_user_settings_defaults

	run sct_agent_post_user_settings_hook claude
	assert_success
	[[ ! -f "$marker" ]]
}

@test "sct_agent_post_user_settings_hook: codex calls ensure_codex_user_settings_defaults when defined" {
	called=""
	ensure_codex_user_settings_defaults() {
		called="yes"
	}
	export -f ensure_codex_user_settings_defaults

	sct_agent_post_user_settings_hook codex

	[ "$called" = "yes" ]
}

@test "sct_agent_post_user_settings_hook: codex with helper missing is a no-op" {
	unset -f ensure_codex_user_settings_defaults
	run sct_agent_post_user_settings_hook codex
	assert_success
	assert_output ""
}

@test "sct_agent_post_user_settings_hook: unknown is a no-op" {
	run sct_agent_post_user_settings_hook unknown
	assert_success
}

@test "sct_agent_post_user_settings_hook: cursor with helper missing is a no-op" {
	# When init isn't sourced, the helper isn't defined. The hook must still
	# succeed (declare -F guard) so unit-testing agents.bash standalone works.
	unset -f ensure_cursor_user_settings_defaults 2>/dev/null || true
	run sct_agent_post_user_settings_hook cursor
	assert_success
}
