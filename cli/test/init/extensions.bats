#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
	mkdir -p "$BATS_TEST_TMPDIR/sandcat/scripts"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	touch "$BATS_TEST_TMPDIR/compose-all.yml"
	touch "$BATS_TEST_TMPDIR/Dockerfile.app"
	touch "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
}

teardown() {
	unstub_all
}

@test "customize_devcontainer_extensions adds extension for python" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions adds multiple extensions" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python java go

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"redhat.java"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"golang.go"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions preserves existing extensions" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"github.vscode-pull-request-github"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions removes __STACK_EXTENSIONS__ placeholder" {
	# The placeholder line must always be consumed, regardless of whether
	# the selected stacks contribute any extension. Bats has no parametric
	# tests, so we cover both branches in a single test:
	#   - "node"   — no extension contribution
	#   - "python" — contributes an extension
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" node
	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure

	# Re-run with an extension-contributing stack on a fresh fixture.
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python
	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure
}

@test "customize_devcontainer_extensions is a no-op for empty stacks" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	customize_devcontainer_extensions "$DEVCONTAINER_JSON"

	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_agent_templates sets cursor extension baseline" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "cursor"

	run grep '"anysphere.cursor"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_agent_templates sets claude mitmproxy defaults" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_claude.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	# Streaming-related flags are Cursor-only; including them on the Claude
	# path would weaken the body-content placeholder leak check in
	# _substitute_secrets (mitmproxy buffers <1MB bodies by default).
	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	# Placeholder must be fully resolved.
	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

@test "customize_agent_templates adds cursor bootstrap settings" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "cursor"

	run grep 'cursor-cli-config.json' "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	assert_success

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_cursor.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

@test "customize_agent_templates sets codex mitmproxy defaults" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "codex"

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_codex.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	# Streaming-related flags are Cursor-only; including them on the Codex
	# path would weaken the body-content placeholder leak check in
	# _substitute_secrets (mitmproxy buffers <1MB bodies by default).
	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	# Placeholder must be fully resolved.
	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}
