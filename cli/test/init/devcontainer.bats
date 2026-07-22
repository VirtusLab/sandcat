#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
}

teardown() {
	unstub_all
}

@test "customize_devcontainer_json replaces __PROJECT_NAME__ in name" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project"

	run grep '"name": "my-project"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json replaces __PROJECT_NAME__ in workspaceFolder" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project"

	run grep '"workspaceFolder": "/workspaces/my-project"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json replaces __PROJECT_NAME__ in postStartCommand" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project"

	run grep '/workspaces/my-project/.devcontainer/sandcat/scripts/app-post-start.sh' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json leaves no __PROJECT_NAME__ placeholders" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project"

	run grep -c '__PROJECT_NAME__' "$DEVCONTAINER_JSON"
	assert_output "0"
}

@test "devcontainer.json template contains __STACK_EXTENSIONS__ placeholder" {
	run grep '__STACK_EXTENSIONS__' "$DEVCONTAINER_JSON"
	assert_success
}

@test "devcontainer.json template sets overrideCommand to false" {
	# Required so the container's ENTRYPOINT (app-init.sh) runs on start —
	# JetBrains Gateway historically defaults overrideCommand to true for
	# compose scenarios, bypassing app-init.sh and sandcat's security setup.
	run grep '"overrideCommand": false' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json keeps customizations.vscode when ide is vscode" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "vscode"

	run grep '"vscode":' "$DEVCONTAINER_JSON"
	assert_success
	refute_output --partial '"jetbrains"'
}

@test "customize_devcontainer_json defaults to vscode when ide is omitted" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project"

	run grep '"vscode":' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json emits customizations.jetbrains when ide is jetbrains" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "jetbrains"

	run grep '"jetbrains":' "$DEVCONTAINER_JSON"
	assert_success
	run grep '"backend": "IntelliJ"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_json omits vscode block when ide is jetbrains" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "jetbrains"

	run grep -c '"vscode":' "$DEVCONTAINER_JSON"
	assert_output "0"
}

@test "customize_devcontainer_json drops customizations block when ide is none" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "none"

	run grep -c '"customizations":' "$DEVCONTAINER_JSON"
	assert_output "0"
}

@test "customize_devcontainer_json strips __CUSTOMIZATIONS markers for vscode" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "vscode"

	run grep -c '__CUSTOMIZATIONS_' "$DEVCONTAINER_JSON"
	assert_output "0"
}

@test "customize_devcontainer_json strips __CUSTOMIZATIONS markers for jetbrains" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "jetbrains"

	run grep -c '__CUSTOMIZATIONS_' "$DEVCONTAINER_JSON"
	assert_output "0"
}

@test "customize_devcontainer_json strips __CUSTOMIZATIONS markers for none" {
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "none"

	run grep -c '__CUSTOMIZATIONS_' "$DEVCONTAINER_JSON"
	assert_output "0"
}
