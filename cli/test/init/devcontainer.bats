#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/claude/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
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
