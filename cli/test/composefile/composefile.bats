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

@test "add_cursor_config_volumes adds customization and state mounts" {
	add_cursor_config_volumes "$COMPOSE_FILE" true "test-project"

	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "10"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/rules:/home/vscode/.cursor/rules:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/skills:/home/vscode/.cursor/skills:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/commands:/home/vscode/.cursor/commands:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/hooks.json:/home/vscode/.cursor/hooks.json:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/hooks:/home/vscode/.cursor/hooks:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/agents:/home/vscode/.cursor/agents:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/mcp.json:/home/vscode/.cursor/mcp.json:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/projects/workspaces-test-project:/home/vscode/.cursor/projects/workspaces-test-project")' "$COMPOSE_FILE"
}


@test "add_codex_config_volumes adds AGENTS.md, skills, and commands" {
	add_codex_config_volumes "$COMPOSE_FILE"

	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "4"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/AGENTS.md:/home/vscode/.codex-host/AGENTS.md:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/skills:/home/vscode/.codex/skills:ro")' "$COMPOSE_FILE"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/commands:/home/vscode/.codex/commands:ro")' "$COMPOSE_FILE"
}

@test "add_codex_config_volumes leaves entries commented when active=false" {
	add_codex_config_volumes "$COMPOSE_FILE" false

	# No new active volume entries — still just the initial one.
	run yq '.services.agent.volumes | length' "$COMPOSE_FILE"
	assert_output "1"

	# All three paths appear as foot-comment lines.
	run yq -P '.services.agent.volumes' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	assert_line '# - ${HOME}/.codex/AGENTS.md:/home/vscode/.codex-host/AGENTS.md:ro'
	# shellcheck disable=SC2016
	assert_line '# - ${HOME}/.codex/skills:/home/vscode/.codex/skills:ro'
	# shellcheck disable=SC2016
	assert_line '# - ${HOME}/.codex/commands:/home/vscode/.codex/commands:ro'
}

@test "add_git_readonly_volume adds .git mount as read-only" {
	add_git_readonly_volume "$COMPOSE_FILE"

	yq -e '.services.agent.volumes[] | select(. == "../.git:/workspace/.git:ro")' "$COMPOSE_FILE"
}

@test "add_idea_readonly_volume adds .idea mount as read-only" {
	add_idea_readonly_volume "$COMPOSE_FILE"

	yq -e '.services.agent.volumes[] | select(. == "../.idea:/workspace/.idea:ro")' "$COMPOSE_FILE"
}

@test "add_shared_cache_volumes with java stack mounts all six JVM cache paths" {
	# shellcheck source=../../lib/stacks.bash
	source "$SCT_LIBDIR/stacks.bash"

	add_shared_cache_volumes "$COMPOSE_FILE" "true" "java"

	# Every SCT_STACK_CACHE_JAVA entry becomes an active volume mount.
	local entry name path
	for entry in "${SCT_STACK_CACHE_JAVA[@]}"; do
		name=${entry%%:*}
		path=${entry#*:}
		mount="$name:$path" yq -e \
			'.services.agent.volumes[] | select(. == env(mount))' "$COMPOSE_FILE"
	done
}

@test "add_shared_cache_volumes declares each cache as an external top-level volume" {
	source "$SCT_LIBDIR/stacks.bash"

	add_shared_cache_volumes "$COMPOSE_FILE" "true" "java"

	# Each cache lives under a stable host-scoped name so multiple compose
	# projects reference the same physical volume; external:true prevents
	# `compose down -v` in one project from wiping caches shared elsewhere.
	local entry name
	for entry in "${SCT_STACK_CACHE_JAVA[@]}"; do
		name=${entry%%:*}
		name="$name" yq -e '.volumes[env(name)].external == true' "$COMPOSE_FILE"
		name="$name" yq -e '.volumes[env(name)].name == env(name)' "$COMPOSE_FILE"
	done
}

@test "add_shared_cache_volumes adds nothing when no matching stack is selected" {
	# python/node/etc. don't contribute shared caches yet — the compose
	# file must stay clean of Maven/Coursier/etc. mounts. This is the
	# case for a Python-only sandbox, which shouldn't carry JVM caches.
	add_shared_cache_volumes "$COMPOSE_FILE" "true" "python" "node"

	run yq -r '.volumes // {} | keys[]' "$COMPOSE_FILE"
	refute_output --partial "sandcat-cache-"

	run grep -F 'sandcat-cache-' "$COMPOSE_FILE"
	assert_failure
}

@test "add_shared_cache_volumes deduplicates when java appears via multiple stacks" {
	source "$SCT_LIBDIR/stacks.bash"

	# resolve_stacks expands "scala" to "java scala"; simulate that flow.
	add_shared_cache_volumes "$COMPOSE_FILE" "true" "java" "scala"

	# Still exactly the six Java entries — no duplicate top-level volumes.
	local expected_count=${#SCT_STACK_CACHE_JAVA[@]}
	run yq -r '.volumes | keys | length' "$COMPOSE_FILE"
	assert_output "$expected_count"
}

@test "add_shared_cache_volumes leaves entries commented when active=false" {
	source "$SCT_LIBDIR/stacks.bash"

	add_shared_cache_volumes "$COMPOSE_FILE" "false" "java"

	# No active mounts appear.
	local entry name
	for entry in "${SCT_STACK_CACHE_JAVA[@]}"; do
		name=${entry%%:*}
		run yq -r '.services.agent.volumes[] | select(. == "'"$name"':*")' "$COMPOSE_FILE"
		assert_output ""
	done

	# No top-level external volumes are declared either.
	for entry in "${SCT_STACK_CACHE_JAVA[@]}"; do
		name=${entry%%:*}
		run bash -c "name='$name' yq -r '.volumes // {} | keys[]' '$COMPOSE_FILE' | grep -q \"^\$name\$\""
		assert_failure
	done

	# Comment lines with the mount specs stay in the file so users can
	# uncomment later.
	run grep -F "sandcat-cache-maven:/home/vscode/.m2/repository" "$COMPOSE_FILE"
	assert_success
}

@test "app-init.sh normalises ownership on every shared-cache mount point" {
	# Docker creates named volumes as root:root. Without a startup chown,
	# vscode can't write to /home/vscode/.m2/repository etc. — the whole
	# shared-cache feature would appear broken with permission-denied.
	local script="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/app-init.sh"
	run grep -F 'chown vscode:vscode "$cache_dir"' "$script"
	assert_success

	# Every mount root + its intermediate parent must be in the loop, so
	# tools that also write next to the mount (Maven settings.xml, Gradle
	# daemon/, etc.) don't fail on the root-owned parent dir.
	local dir
	for dir in \
		/home/vscode/.m2 \
		/home/vscode/.m2/repository \
		/home/vscode/.cache \
		/home/vscode/.cache/coursier \
		/home/vscode/.gradle \
		/home/vscode/.gradle/wrapper \
		/home/vscode/.gradle/caches \
		/home/vscode/.gradle/wrapper/dists \
		/home/vscode/.ivy2 \
		/home/vscode/.ivy2/cache \
		/home/vscode/.sbt \
		/home/vscode/.sbt/boot
	do
		run grep -F "$dir" "$script"
		assert_success
	done
}

@test "customize_compose_file honours SANDCAT_MOUNT_SHARED_CACHE=false" {
	# The env-var toggle is the primary opt-out path. Even for a java
	# stack that normally gets shared caches, disabling the flag must
	# keep the compose file free of shared-cache mounts + external
	# volume declarations.
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	SANDCAT_MOUNT_SHARED_CACHE=false \
		customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "claude" "vscode" "test-project" "java"

	run yq -r '.volumes // {} | keys[]' "$COMPOSE_FILE"
	refute_output --partial "sandcat-cache-"
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

	# With JetBrains IDE, the .idea mount is also active by default.
	# 1 initial + 3 workspace + 3 Claude + 1 .idea = 8 active volumes.
	# No shared-cache volumes because this call passes no stacks.
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
	# Dispatch smoke: representative cursor mounts; full list is covered by
	# `add_cursor_config_volumes adds customization and state mounts`.
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "cursor" "vscode" "test-project"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/commands:/home/vscode/.cursor/commands:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/hooks.json:/home/vscode/.cursor/hooks.json:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/agents:/home/vscode/.cursor/agents:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.cursor/projects/workspaces-test-project:/home/vscode/.cursor/projects/workspaces-test-project")' "$COMPOSE_FILE"
	# No claude volumes leak through when agent=cursor.
	run yq '.services.agent.volumes[] | select(test("\\.claude/"))' "$COMPOSE_FILE"
	assert_output ""
}

# shellcheck disable=SC2016
@test "customize_compose_file dispatches to add_codex_config_volumes for codex agent" {
	# Dispatch smoke: all three codex mounts must appear; no claude/cursor volumes leak.
	SETTINGS_FILE=".sandcat/settings.json"
	mkdir -p "$BATS_TEST_TMPDIR/.sandcat"
	touch "$BATS_TEST_TMPDIR/$SETTINGS_FILE"

	customize_compose_file "$SETTINGS_FILE" "$COMPOSE_FILE" "codex" "vscode" "test-project"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/AGENTS.md:/home/vscode/.codex-host/AGENTS.md:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/skills:/home/vscode/.codex/skills:ro")' "$COMPOSE_FILE"
	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.codex/commands:/home/vscode/.codex/commands:ro")' "$COMPOSE_FILE"
	# No claude or cursor volumes leak through.
	run yq '.services.agent.volumes[] | select(test("\\.claude/|\\.cursor/"))' "$COMPOSE_FILE"
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
