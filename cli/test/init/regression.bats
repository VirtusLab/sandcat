#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# This is a regression test verifying that docker-compose configuration is generated correctly.

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/$SCT_PROJECT_DIR"

	POLICY_FILE="$SCT_PROJECT_DIR/settings.json"
	touch "$PROJECT_DIR/$POLICY_FILE"
}

teardown() {
	unstub_all
}

assert_proxy_service() {
	local compose_file=$1

	yq -e '.services.mitmproxy.cap_drop[] | select(. == "ALL")' "$compose_file"

	yq -e '.services.mitmproxy.environment[] | select(. == "PROXY_MODE=enforce")' "$compose_file"
}

assert_agent_service_base() {
	local compose_file=$1

	run yq '.services.agent.working_dir' "$compose_file"
	assert_output "/workspace"

	yq -e '.services.agent.cap_drop[] | select(. == "ALL")' "$compose_file"
}

assert_common_environment_vars() {
	local compose_file=$1

	yq -e '.services.agent.environment[] | select(. == "HTTP_PROXY=http://proxy:8080")' "$compose_file"

	yq -e '.services.agent.environment[] | select(. == "HTTPS_PROXY=http://proxy:8080")' "$compose_file"

	yq -e '.services.agent.environment[] | select(. == "NO_PROXY=localhost,127.0.0.1,proxy")' "$compose_file"
}

assert_common_volumes() {
	local compose_file=$1

	yq -e '.services.agent.volumes[] | select(. == "..:/workspace")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "../.sandcat:/workspace/.sandcat:ro")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "proxy-ca:/etc/mitmproxy:ro")' "$compose_file"
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

assert_customization_volumes() {
	local compose_file=$1

	yq -e '.services.mitmproxy.volumes[] | select(. == "../'"$SCT_PROJECT_DIR"'/settings.json:/etc/mitmproxy/policy.yaml:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.config/sandcat/shell.d:/home/dev/.config/sandcat/shell.d:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.config/sandcat/dotfiles:/home/dev/.dotfiles:ro")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "../.git:/workspace/.git:ro")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "../.idea:/workspace/.idea:ro")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "../.vscode:/workspace/.vscode:ro")' "$compose_file"
}

assert_devcontainer_volume() {
	local compose_file=$1

	yq -e '.services.agent.volumes[] | select(. == ".:/workspace/.devcontainer:ro")' "$compose_file"
}

assert_jetbrains_capabilities() {
	local compose_file=$1

	yq -e '.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "CHOWN")' "$compose_file"
	yq -e '.services.agent.cap_add[] | select(. == "FOWNER")' "$compose_file"
}

claude_agent_compose_file_has_expected_content() {
	local compose_file=$1

	assert [ -f "$compose_file" ]

	assert_proxy_service "$compose_file"
	assert_agent_service_base "$compose_file"

	yq -e '.services.agent.environment[] | select(. == "CLAUDE_CONFIG_DIR=/home/dev/.claude")' "$compose_file"

	assert_common_environment_vars "$compose_file"
	assert_common_volumes "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "claude-state:/home/dev/.claude")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "claude-history:/commandhistory")' "$compose_file"

	assert_named_volumes "$compose_file" "claude-state" "claude-history" "proxy-state" "proxy-ca"
	assert_customization_volumes "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/CLAUDE.md:/home/dev/.claude/CLAUDE.md:ro")' "$compose_file"

	# shellcheck disable=SC2016
	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.claude/settings.json:/home/dev/.claude/settings.json:ro")' "$compose_file"
}

copilot_agent_compose_file_has_expected_content() {
	local compose_file=$1

	assert [ -f "$compose_file" ]

	assert_proxy_service "$compose_file" "ghcr.io/VirtusLab/sandcat-proxy@sha256:abc123"
	assert_agent_service_base "$compose_file" "ghcr.io/VirtusLab/sandcat-copilot@sha256:ghi789"
	assert_common_environment_vars "$compose_file"
	assert_common_volumes "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "copilot-state:/home/dev/.copilot")' "$compose_file"

	yq -e '.services.agent.volumes[] | select(. == "copilot-history:/commandhistory")' "$compose_file"

	assert_named_volumes "$compose_file" "copilot-state" "copilot-history" "proxy-state" "proxy-ca"
	assert_customization_volumes "$compose_file"
	# shellcheck disable=SC2016
	run yq '.services.agent.volumes[] | select(. == "${HOME}/.claude/CLAUDE.md:/home/dev/.claude/CLAUDE.md:ro")' "$compose_file"
	assert_output ""
}

@test "devcontainer creates compose-all.yml for claude agent with all options enabled" {
	skip 'FIXME: compose is split into multiple files'
	export SANDCAT_MOUNT_CLAUDE_CONFIG="true"
	export SANDCAT_ENABLE_DOTFILES="true"
	export SANDCAT_MOUNT_GIT_READONLY="true"
	export SANDCAT_MOUNT_IDEA_READONLY="true"
	export SANDCAT_MOUNT_VSCODE_READONLY="true"

	run devcontainer \
		--policy-file "$POLICY_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent "claude" \
		--ide "jetbrains"
	assert_success
	assert_output --regexp ".*Devcontainer dir created at $PROJECT_DIR/.devcontainer"

	run yq '.name' "$PROJECT_DIR/.devcontainer/compose-all.yml"
	assert_output "project-sandbox-devcontainer"

	claude_agent_compose_file_has_expected_content "$PROJECT_DIR/.devcontainer/compose-all.yml"

	assert_devcontainer_volume "$PROJECT_DIR/.devcontainer/compose-all.yml"
	assert_jetbrains_capabilities "$PROJECT_DIR/.devcontainer/compose-all.yml"
}
