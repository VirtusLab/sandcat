#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/init
	source "$SCT_LIBEXECDIR/init/init"
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR"

	SCT_HOME_DIR="$BATS_TEST_TMPDIR/config/sandcat"
	mkdir -p "$SCT_HOME_DIR"
	sct_home() { echo "$SCT_HOME_DIR"; }
	export -f sct_home

	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
}

teardown() {
	unstub_all
}

@test "init rejects --proxy-peer without --netbird" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none --proxy-peer
	assert_failure
	assert_output --partial "--proxy-peer requires --netbird"
}

@test "init rejects --proxy-peer without --capability" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none \
		--netbird --netbird-server cloud --proxy-peer
	assert_failure
	assert_output --partial "--proxy-peer requires --capability"
}

@test "init --netbird --capability --proxy-peer copies compose-proxy-peer.yml" {
	mkdir -p "$PROJECT_DIR/.sandcat"
	touch "$PROJECT_DIR/.sandcat/settings.json"
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none \
		--netbird --netbird-server cloud --capability --proxy-peer
	assert_success

	[[ -f "$PROJECT_DIR/.devcontainer/sandcat/compose-proxy-peer.yml" ]]
	[[ -f "$PROJECT_DIR/.devcontainer/sandcat/Dockerfile.proxy-peer" ]]
	[[ -f "$PROJECT_DIR/.devcontainer/sandcat/scripts/proxy-peer-init.sh" ]]
	[[ -f "$PROJECT_DIR/.devcontainer/sandcat/scripts/proxy-peer-hello.py" ]]
}

@test "init --proxy-peer registers compose-proxy-peer.yml include" {
	mkdir -p "$PROJECT_DIR/.sandcat"
	touch "$PROJECT_DIR/.sandcat/settings.json"
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none \
		--netbird --netbird-server cloud --capability --proxy-peer
	assert_success

	# Copying the file is not enough: without the include the proxy-peer
	# service never joins the stack.
	run yq '[.include[] | select(.path == "sandcat/compose-proxy-peer.yml")] | length' \
		"$PROJECT_DIR/.devcontainer/compose-all.yml"
	assert_output "1"
}

@test "init --netbird --proxy-peer copies settings.proxy-peer.example.json" {
	mkdir -p "$PROJECT_DIR/.sandcat"
	touch "$PROJECT_DIR/.sandcat/settings.json"
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none \
		--netbird --netbird-server cloud --capability --proxy-peer
	assert_success

	[[ -f "$PROJECT_DIR/.sandcat/settings.proxy-peer.example.json" ]]
	# The dns_label FQDN survives a proxy-peer recreate; the mesh IP it replaced
	# did not, and had to be pasted in by hand after every rebuild.
	run yq -r '.network[0].host' "$PROJECT_DIR/.sandcat/settings.proxy-peer.example.json"
	assert_output "peer-proxy.netbird.selfhosted"
}
