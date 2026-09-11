#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/netbird.bash"

	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/sandcat"
	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/.sandcat"
	cd "$PROJECT_DIR" || return 1
}

teardown() {
	unstub_all
}

# CI ships mikefarah yq in /usr/bin (often usr-merged with /bin), so
# PATH=/usr/bin:/bin still finds it — same trap as require.bats. Keep the
# utilities these tests need, omit yq.
path_without_yq() {
	local fake_bin="$BATS_TEST_TMPDIR/no-yq-bin"
	mkdir -p "$fake_bin"
	local cmd
	for cmd in bash sh mkdir rm cp mv cat grep mktemp chmod ln stat; do
		if command -v "$cmd" >/dev/null 2>&1 && [[ ! -e "$fake_bin/$cmd" ]]; then
			ln -s "$(command -v "$cmd")" "$fake_bin/$cmd"
		fi
	done
	printf '%s' "$fake_bin"
}

@test "netbird_read_setting returns empty when no settings exist" {
	run netbird_read_setting netbird_api_token
	assert_success
	assert_output ""
}

@test "netbird_read_setting does not require yq when the key is absent" {
	echo '{"unrelated": true}' > "$HOME/.config/sandcat/settings.json"
	PATH="$(path_without_yq)" run netbird_read_setting netbird_api_token
	assert_success
	assert_output ""
}

@test "export_netbird_compose_env does not require yq when NetBird keys are absent" {
	echo '{"unrelated": true}' > "$HOME/.config/sandcat/settings.json"
	unset NB_SETUP_KEY NB_API_TOKEN
	PATH="$(path_without_yq)" run export_netbird_compose_env
	assert_success
	refute_output --partial "yq required"
}

@test "prepare_agent_sandcat_mount does not require yq when settings files are empty" {
	: > "$PROJECT_DIR/.sandcat/settings.json"
	local dest="$BATS_TEST_TMPDIR/agent-sandcat"
	PATH="$(path_without_yq)" run prepare_agent_sandcat_mount "$PROJECT_DIR/.sandcat" "$dest"
	assert_success
	[[ -f "$dest/settings.json" ]]
}

@test "prepare_agent_sandcat_mount fails closed when yq is missing and settings exist" {
	echo '{"netbird_api_token":"tok"}' > "$PROJECT_DIR/.sandcat/settings.json"
	local dest="$BATS_TEST_TMPDIR/agent-sandcat"
	PATH="$(path_without_yq)" run prepare_agent_sandcat_mount "$PROJECT_DIR/.sandcat" "$dest"
	assert_failure
	refute_output --partial "tok"
	[[ ! -e "$dest" ]]
}

@test "export_agent_sandcat_mount does not export dest when prepare fails" {
	echo '{"netbird_enrollment_key":"key"}' > "$PROJECT_DIR/.sandcat/settings.json"
	local dest
	dest="$(sct_home)/agent-sandcat/${PROJECT_DIR//\//_}"
	PATH="$(path_without_yq)" run export_agent_sandcat_mount
	assert_failure
	[[ ! -e "$dest" ]]
}

@test "export_agent_sandcat_mount writes SANDCAT_AGENT_SANDCAT into .devcontainer/.env" {
	mkdir -p "$PROJECT_DIR/.devcontainer"
	export_agent_sandcat_mount
	[[ -n "${SANDCAT_AGENT_SANDCAT:-}" ]]
	run grep -F "SANDCAT_AGENT_SANDCAT=$SANDCAT_AGENT_SANDCAT" "$PROJECT_DIR/.devcontainer/.env"
	assert_success
	local mode
	mode=$(stat -c '%a' "$PROJECT_DIR/.devcontainer/.env" 2>/dev/null \
		|| stat -f '%OLp' "$PROJECT_DIR/.devcontainer/.env")
	assert_equal "$mode" "600"
}

@test "netbird_read_setting reads netbird_api_token from user settings" {
	echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"

	run netbird_read_setting netbird_api_token
	assert_output "user-token"
}

@test "netbird_read_setting ignores project-layer API token" {
	echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"
	echo '{"netbird_api_token": "project-token"}' > "$PROJECT_DIR/.sandcat/settings.json"

	run netbird_read_setting netbird_api_token
	assert_output "user-token"
}

@test "netbird_read_setting ignores local project API token" {
	echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"
	echo '{"netbird_api_token": "project-token"}' > "$PROJECT_DIR/.sandcat/settings.json"
	echo '{"netbird_api_token": "local-token"}' > "$PROJECT_DIR/.sandcat/settings.local.json"

	run netbird_read_setting netbird_api_token
	assert_output "user-token"
}

@test "netbird_read_setting still prefers project settings for management URL" {
	echo '{"netbird_management_url": "https://user.example.com"}' > "$HOME/.config/sandcat/settings.json"
	echo '{"netbird_management_url": "https://project.example.com"}' > "$PROJECT_DIR/.sandcat/settings.json"

	run netbird_read_setting netbird_management_url
	assert_output "https://project.example.com"
}

@test "export_netbird_compose_env exports enrollment key from user settings" {
	echo '{"netbird_enrollment_key": "setup-key-123"}' > "$HOME/.config/sandcat/settings.json"
	unset NB_SETUP_KEY

	export_netbird_compose_env

	[[ "$NB_SETUP_KEY" == "setup-key-123" ]]
}

@test "export_netbird_compose_env does not override existing NB_SETUP_KEY" {
	echo '{"netbird_enrollment_key": "from-settings"}' > "$HOME/.config/sandcat/settings.json"
	export NB_SETUP_KEY="from-env"

	export_netbird_compose_env

	[[ "$NB_SETUP_KEY" == "from-env" ]]
}

@test "export_netbird_compose_env exports API token from user settings" {
	echo '{"netbird_api_token": "api-token-456"}' > "$HOME/.config/sandcat/settings.json"
	unset NB_API_TOKEN

	export_netbird_compose_env

	[[ "$NB_API_TOKEN" == "api-token-456" ]]
}

@test "export_netbird_compose_env does not override existing NB_API_TOKEN" {
	echo '{"netbird_api_token": "from-settings"}' > "$HOME/.config/sandcat/settings.json"
	export NB_API_TOKEN="from-env"

	export_netbird_compose_env

	[[ "$NB_API_TOKEN" == "from-env" ]]
}

@test "export_netbird_management_url exports management URL from user settings" {
	echo '{"netbird_management_url": "https://management.example.com"}' > "$HOME/.config/sandcat/settings.json"
	unset NB_MANAGEMENT_URL

	export_netbird_management_url

	[[ "$NB_MANAGEMENT_URL" == "https://management.example.com" ]]
}

@test "export_netbird_management_url does not override existing NB_MANAGEMENT_URL" {
	echo '{"netbird_management_url": "https://from-settings.example.com"}' > "$HOME/.config/sandcat/settings.json"
	export NB_MANAGEMENT_URL="https://from-env.example.com"

	export_netbird_management_url

	[[ "$NB_MANAGEMENT_URL" == "https://from-env.example.com" ]]
}

@test "netbird_enrollment_management_url_from returns empty for localhost without explicit enrollment URL" {
	run netbird_enrollment_management_url_from "http://localhost:33073"
	assert_output ""
}

@test "netbird_enrollment_management_url_from returns empty for 127.0.0.1 without explicit enrollment URL" {
	run netbird_enrollment_management_url_from "http://127.0.0.1:33073"
	assert_output ""
}

@test "netbird_enrollment_management_url_from leaves remote URLs unchanged" {
	run netbird_enrollment_management_url_from "https://netbird.example.com"
	assert_output "https://netbird.example.com"
}

@test "netbird_enrollment_management_url_from prefers netbird_enrollment_management_url setting" {
	echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

	run netbird_enrollment_management_url_from "http://localhost:33073"
	assert_output "http://192.168.5.2:33073"
}

@test "netbird_detect_docker_host_ip extracts the host LAN address on Linux" {
	stub uname "-s : echo Linux"
	stub ip "-4 route get 1.1.1.1 : echo '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 1000'"

	run netbird_detect_docker_host_ip
	assert_success
	assert_output "192.168.1.50"
}

@test "netbird_detect_docker_host_ip prints nothing when no IPv4 is found" {
	stub uname "-s : echo Linux"
	stub ip "-4 route get 1.1.1.1 : echo ''"

	run netbird_detect_docker_host_ip
	assert_success
	assert_output ""
}

@test "netbird_enrollment_url_uses_host_bypass for literal IPv4 enrollment URL" {
	run netbird_enrollment_url_uses_host_bypass "http://192.168.5.2:33073"
	assert_success
}

@test "netbird_enrollment_url_uses_host_bypass is false for hostname enrollment URL" {
	run netbird_enrollment_url_uses_host_bypass "https://netbird.example.com"
	assert_failure
}

@test "netbird_read_setting uses SANDCAT_PROJECT_ROOT instead of PWD" {
	local other="$BATS_TEST_TMPDIR/other-project"
	mkdir -p "$other/.sandcat" "$HOME/.config/sandcat"
	echo '{"netbird_management_url": "https://pwd.example.com"}' > "$PROJECT_DIR/.sandcat/settings.json"
	echo '{"netbird_management_url": "https://path.example.com"}' > "$other/.sandcat/settings.json"
	echo '{}' > "$HOME/.config/sandcat/settings.json"

	cd "$PROJECT_DIR"
	SANDCAT_PROJECT_ROOT="$other" run netbird_read_setting netbird_management_url
	assert_output "https://path.example.com"
}
