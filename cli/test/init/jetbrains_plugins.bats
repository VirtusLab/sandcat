#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"

	# Emit the JetBrains customizations block so plugins tests have
	# `"plugins": []` to rewrite. This mirrors the production order:
	# customize_devcontainer_json runs before customize_devcontainer_plugins.
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "jetbrains"
}

teardown() {
	unstub_all
}

@test "customize_devcontainer_plugins inserts a plugin for a stack that has one" {
	customize_devcontainer_plugins "$DEVCONTAINER_JSON" "scala"

	run grep '"plugins": \["org.intellij.scala"\]' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_plugins joins multiple plugin ids" {
	customize_devcontainer_plugins "$DEVCONTAINER_JSON" "scala" "python" "go"

	run grep '"plugins": \["org.intellij.scala", "PythonCore", "org.jetbrains.plugins.go"\]' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_plugins keeps empty array when no stack contributes a plugin" {
	# java is bundled — stack_jetbrains_plugin returns empty for it.
	customize_devcontainer_plugins "$DEVCONTAINER_JSON" "java"

	run grep '"plugins": \[\]' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_plugins keeps empty array when called with no stacks" {
	customize_devcontainer_plugins "$DEVCONTAINER_JSON"

	run grep '"plugins": \[\]' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_plugins skips stacks whose plugin is bundled" {
	# Mixing java (bundled → skipped) and scala (has plugin) should
	# produce only the scala plugin.
	customize_devcontainer_plugins "$DEVCONTAINER_JSON" "java" "scala"

	run grep '"plugins": \["org.intellij.scala"\]' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_plugins does nothing when called on a vscode devcontainer.json" {
	# Reset to a fresh vscode-style file (no jetbrains block, no `"plugins": []`).
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
	customize_devcontainer_json "$DEVCONTAINER_JSON" "my-project" "vscode"

	customize_devcontainer_plugins "$DEVCONTAINER_JSON" "scala"

	# vscode block has "extensions": [...] but no "plugins": [] to rewrite.
	# The function should have been a no-op.
	run grep 'org.intellij.scala' "$DEVCONTAINER_JSON"
	assert_failure
}
