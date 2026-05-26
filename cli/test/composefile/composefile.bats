#!/usr/bin/env bats
# bashsupport disable=GrazieInspection
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"

	COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-all.yml"

	cat >"$COMPOSE_FILE" <<'YAML'
services:
  proxy:
    image: placeholder
    volumes: []
  agent:
    image: placeholder
    volumes:
      - ../:/workspace # need at least one entry so that we can add foot comments
    cap_add:
      - SOME_CAPABILITY # need at least one entry so that we can add foot comments
YAML
}

teardown() {
	unstub_all
}

@test "add_settings_volume adds settings mount to proxy service" {
	add_settings_volume "$COMPOSE_FILE" ".sandcat/settings.json"

	yq -e '.services.mitmproxy.volumes[] | select(. == ".sandcat:/config/project:ro")' "$COMPOSE_FILE"
}

@test "add_claude_config_volumes adds CLAUDE.md and settings.json" {
	add_claude_config_volumes "$COMPOSE_FILE"

	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "4"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/agents:/home/vscode/.claude/agents:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/commands:/home/vscode/.claude/commands:ro")' "$COMPOSE_FILE"
}

@test "add_cursor_config_volumes adds AGENTS.md, rules, and skills" {
	add_cursor_config_volumes "$COMPOSE_FILE"

	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "4"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/rules:/home/vscode/.cursor/rules:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/skills:/home/vscode/.cursor/skills:ro")' "$COMPOSE_FILE"
}


@test "add_git_readonly_volume adds .git mount as read-only" {
	add_git_readonly_volume "$COMPOSE_FILE"

	yq -e '.services.agent.volumes[] | select(. == "../.git:/workspace/.git:ro")' "$COMPOSE_FILE"
}

@test "add_idea_readonly_volume adds .idea mount as read-only" {
	add_idea_readonly_volume "$COMPOSE_FILE"

	yq -e '.services.agent.volumes[] | select(. == "../.idea:/workspace/.idea:ro")' "$COMPOSE_FILE"
}

assert_jetbrains_capabilities() {
	local compose_file=$1

	yq -e '.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "CHOWN")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "FOWNER")' "$compose_file"

	run yq '(.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")) | head_comment' "$compose_file"
	assert_output "JetBrains IDE: bypass file permission checks on mounted volumes"
}

assert_customize_compose_file_common() {
	local compose_file=$1

	# Verify settings volume on proxy
	yq -e '.services.mitmproxy.volumes[] | select(. == ".sandcat:/config/project:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/agents:/home/vscode/.claude/agents:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/commands:/home/vscode/.claude/commands:ro")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "../.git:/workspace/.git:ro")' "$compose_file"
}

@test "add_jetbrains_capabilities adds JetBrains-specific capabilities" {
	add_jetbrains_capabilities "$COMPOSE_FILE"

	assert_jetbrains_capabilities "$COMPOSE_FILE"
}

@test "add_volume_entry adds volume when active is true" {
	add_volume_entry "$COMPOSE_FILE" "../test:/workspace/test:ro" "true"

	yq -e '.services.agent.volumes[] | select(. == "../test:/workspace/test:ro")' "$COMPOSE_FILE"
}

@test "add_volume_entry adds volume with head comment when active is true" {
	add_volume_entry "$COMPOSE_FILE" "../test:/workspace/test:ro" "true" "Test volume"

	yq -e '.services.agent.volumes[] | select(. == "../test:/workspace/test:ro")' "$COMPOSE_FILE"

	run yq '.services.agent.volumes[-1] | head_comment' "$COMPOSE_FILE"
	assert_output "Test volume"
}

@test "add_volume_entry adds comment when active is false" {
	add_volume_entry "$COMPOSE_FILE" "../test:/workspace/test:ro" "false"

	# Verify we have one active volume entry
	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "1"

	# Verify foot comment was added to the last entry
	run yq '.services.agent.volumes[-1] | foot_comment' "$COMPOSE_FILE"
	assert_output "- ../test:/workspace/test:ro"
}

@test "add_volume_entry adds description and entry as single foot comment when inactive" {
	add_volume_entry "$COMPOSE_FILE" "../test:/workspace/test:ro" "false" "Test volume"

	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "1"

	run yq '.services.agent.volumes[-1] | foot_comment' "$COMPOSE_FILE"
	assert_output - <<EOF
Test volume
- ../test:/workspace/test:ro
EOF
}

@test "add_volume_entry appends multiple comments" {
	add_volume_entry "$COMPOSE_FILE" "../test1:/workspace/test1:ro" "false"
	add_volume_entry "$COMPOSE_FILE" "../test2:/workspace/test2:ro" "false"
	add_volume_entry "$COMPOSE_FILE" "../test3:/workspace/test3:ro" "false"

	# Verify we still have one active volume entry
	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "1"

	# Verify all foot comments were appended
	run yq '.services.agent.volumes[-1] | foot_comment' "$COMPOSE_FILE"
	assert_output - <<EOF
- ../test1:/workspace/test1:ro
- ../test2:/workspace/test2:ro
- ../test3:/workspace/test3:ro
EOF
}

@test "set_workspace adds working_dir and workspace volumes" {
	set_workspace "$COMPOSE_FILE" "my-project"

	run yq '.services.agent.working_dir' "$COMPOSE_FILE"
	assert_output "/workspaces/my-project"

	yq -e '.services.agent.volumes[] | select(. == "..:/workspaces/my-project")' "$COMPOSE_FILE"
	yq -e '.services.agent.volumes[] | select(. == "../.devcontainer:/workspaces/my-project/.devcontainer:ro")' "$COMPOSE_FILE"
	yq -e '.services.agent.volumes[] | select(. == "../.sandcat:/workspaces/my-project/.sandcat:ro")' "$COMPOSE_FILE"
}

# shellcheck disable=SC2016
@test "customize_compose_file defaults Claude config volumes to active entries" {
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "claude" "jetbrains" "test-project"

	# Verify Claude config volumes are active
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro")' "$COMPOSE_FILE"
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/agents:/home/vscode/.claude/agents:ro")' "$COMPOSE_FILE"
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/commands:/home/vscode/.claude/commands:ro")' "$COMPOSE_FILE"

	# With JetBrains IDE, the .idea mount is also active by default
	# 1 initial + 3 workspace + 3 Claude + 1 .idea = 8 active volumes
	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "8"
}

# shellcheck disable=SC2016
@test "customize_compose_file defaults non-Claude optional volumes to commented-out entries" {
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "claude" "jetbrains" "test-project"

	# Verify settings volume on proxy
	yq -e '.services.mitmproxy.volumes[] | select(. == ".sandcat:/config/project:ro")' "$COMPOSE_FILE"

	# Verify .idea volume is active
	yq -e '.services.agent.volumes[] | select(. == "../.idea:/workspace/.idea:ro")' "$COMPOSE_FILE"

	# Optional inactive mounts should be present as foot comments on the initial workspace volume entry
	# Note: sed on line 92 of composefile.bash merges foot comments into the next sibling as head comments
	# so the yq's foot_comment is empty.
	run yq -P '.services.agent.volumes' "$COMPOSE_FILE"
	assert_line '# - ../.git:/workspace/.git:ro'

	# JetBrains capabilities should still be added
	assert_jetbrains_capabilities "$COMPOSE_FILE"
}

@test "customize_compose_file handles full workflow with all options enabled and jetbrains ide" {
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	export SANDCAT_MOUNT_CLAUDE_CONFIG="true"
	export SANDCAT_MOUNT_GIT_READONLY="true"
	export SANDCAT_MOUNT_IDEA_READONLY="true"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "claude" "jetbrains" "test-project"

	assert_customize_compose_file_common "$COMPOSE_FILE"
	yq -e '.services.agent.volumes[] | select(. == "../.idea:/workspace/.idea:ro")' "$COMPOSE_FILE"
	assert_jetbrains_capabilities "$COMPOSE_FILE"
}

@test "customize_compose_file handles full workflow with all options enabled and vscode ide" {
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	export SANDCAT_MOUNT_CLAUDE_CONFIG="true"
	export SANDCAT_MOUNT_GIT_READONLY="true"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "claude" "vscode" "test-project"

	assert_customize_compose_file_common "$COMPOSE_FILE"
}

# shellcheck disable=SC2016
@test "customize_compose_file dispatches to add_cursor_config_volumes for cursor agent" {
	# We assert the dispatch (one Cursor-specific volume present) rather than
	# re-listing every cursor mount; the per-volume contract is covered by
	# `add_cursor_config_volumes adds AGENTS.md, rules, and skills`.
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "cursor" "vscode" "test-project"

	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro")' "$COMPOSE_FILE"
	# No claude volumes leak through when agent=cursor.
	run yq '.services.agent.volumes[] | select(test("\\.claude/"))' "$COMPOSE_FILE"
	assert_output ""
}

@test "set_proxy_tui_mode keeps addon path and mitm flags" {
	# Claude path: streaming flags are intentionally absent so that
	# _substitute_secrets keeps body-content leak detection. set_proxy_tui_mode
	# must not silently re-introduce them by rewriting the command line.
	local proxy_compose="$BATS_TEST_TMPDIR/compose-proxy.yml"
	cat >"$proxy_compose" <<'YAML'
services:
  mitmproxy:
    command: mitmweb --mode wireguard --web-host 0.0.0.0 --set web_password=mitmproxy --set http2=true -s /scripts/mitmproxy_addon_claude.py
    ports:
      - "8081"
YAML

	set_proxy_tui_mode "$proxy_compose"

	run yq -r '.services.mitmproxy.command' "$proxy_compose"
	assert_output "mitmdump --mode wireguard --set http2=true -s /scripts/mitmproxy_addon_claude.py"

	yq -e '.services.mitmproxy.command | contains("/scripts/mitmproxy_addon_claude.py")' "$proxy_compose"
	yq -e '.services.mitmproxy.command | contains("stream_large_bodies") | not' "$proxy_compose"
	yq -e '.services.mitmproxy | has("ports") | not' "$proxy_compose"
}

@test "set_proxy_tui_mode keeps cursor addon path" {
	local proxy_compose="$BATS_TEST_TMPDIR/compose-proxy-cursor.yml"
	cat >"$proxy_compose" <<'YAML'
services:
  mitmproxy:
    command: mitmweb --mode wireguard --set http2=true --set stream_large_bodies=1m --set connection_strategy=lazy --set anticomp=true --set timeout_read=300 -s /scripts/mitmproxy_addon_cursor.py
    ports:
      - "8081"
YAML

	set_proxy_tui_mode "$proxy_compose"

	run yq -r '.services.mitmproxy.command' "$proxy_compose"
	assert_output "mitmdump --mode wireguard --set http2=true --set stream_large_bodies=1m --set connection_strategy=lazy --set anticomp=true --set timeout_read=300 -s /scripts/mitmproxy_addon_cursor.py"
	yq -e '.services.mitmproxy.command | contains("/scripts/mitmproxy_addon_cursor.py")' "$proxy_compose"
}

@test "apply_secret_provider configures 1password proxy image/env" {
	local proxy_compose="$BATS_TEST_TMPDIR/compose-proxy.yml"
	cat >"$proxy_compose" <<'YAML'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
YAML

	apply_secret_provider "$proxy_compose" "1password"

	yq -e '.services.mitmproxy.image == "ghcr.io/virtuslab/sandcat-mitmproxy-op:latest"' "$proxy_compose"
	yq -e '.services.mitmproxy.environment[] | select(. == "OP_SERVICE_ACCOUNT_TOKEN")' "$proxy_compose"
}

@test "apply_secret_provider configures protonpass proxy image/env" {
	local proxy_compose="$BATS_TEST_TMPDIR/compose-proxy-pass.yml"
	cat >"$proxy_compose" <<'YAML'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
YAML

	apply_secret_provider "$proxy_compose" "protonpass"

	yq -e '.services.mitmproxy.image == "ghcr.io/virtuslab/sandcat-mitmproxy-pass:latest"' "$proxy_compose"
	yq -e '.services.mitmproxy.environment[] | select(. == "PROTON_PASS_PERSONAL_ACCESS_TOKEN")' "$proxy_compose"
}

@test "apply_secret_provider leaves default image for none" {
	local proxy_compose="$BATS_TEST_TMPDIR/compose-proxy-none.yml"
	cat >"$proxy_compose" <<'YAML'
services:
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
YAML

	apply_secret_provider "$proxy_compose" "none"

	yq -e '.services.mitmproxy.image == "mitmproxy/mitmproxy:latest"' "$proxy_compose"
}
