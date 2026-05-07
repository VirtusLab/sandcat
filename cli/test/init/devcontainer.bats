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

@test "apply_template_placeholders fails when target file is missing" {
	run apply_template_placeholders "$BATS_TEST_TMPDIR/missing.txt" "__X__" "y"
	assert_failure
	assert_output --partial "file not found"
}

@test "apply_inline_placeholders fails when target file is missing" {
	run apply_inline_placeholders "$BATS_TEST_TMPDIR/missing.txt" "__X__" "y"
	assert_failure
	assert_output --partial "file not found"
}

@test "verify_no_placeholders passes when no placeholders remain" {
	mkdir -p "$BATS_TEST_TMPDIR/dc"
	echo "all good here" > "$BATS_TEST_TMPDIR/dc/file.txt"
	run verify_no_placeholders "$BATS_TEST_TMPDIR/dc"
	assert_success
}

@test "verify_no_placeholders fails when a placeholder remains" {
	mkdir -p "$BATS_TEST_TMPDIR/dc"
	echo "still has __AGENT_MITM_ADDON__ here" > "$BATS_TEST_TMPDIR/dc/file.txt"
	run verify_no_placeholders "$BATS_TEST_TMPDIR/dc"
	assert_failure
	assert_output --partial "Unsubstituted template placeholders"
	assert_output --partial "__AGENT_MITM_ADDON__"
}
