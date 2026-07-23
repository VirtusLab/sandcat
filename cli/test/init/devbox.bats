#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	DEVCONTAINER_DIR="$BATS_TEST_TMPDIR/devcontainer"
	mkdir -p "$DEVCONTAINER_DIR"
	cp "$SCT_TEMPLATEDIR/devcontainer/Dockerfile.app" "$DEVCONTAINER_DIR/Dockerfile.app"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/$SCT_PROJECT_DIR"

	SETTINGS_FILE="$SCT_PROJECT_DIR/settings.json"
	touch "$PROJECT_DIR/$SETTINGS_FILE"
}

teardown() {
	unstub_all
}

@test "Dockerfile.app template contains __DEVBOX_INSTALL__ placeholder" {
	run grep '# __DEVBOX_INSTALL__' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "customize_devbox expands the install block" {
	customize_devbox "$DEVCONTAINER_DIR"

	run grep 'get.jetify.com/devbox' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep 'devbox global install' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep '/etc/profile.d/sandcat-devbox.sh' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "customize_devbox copies the starter devbox.json" {
	customize_devbox "$DEVCONTAINER_DIR"

	# devbox.json carries // comments (devbox parses HuJSON), so count
	# packages with grep instead of a strict-JSON parser like yq.
	run grep -c '@latest' "$DEVCONTAINER_DIR/devbox.json"
	assert_output "7"
	run grep '"ripgrep@latest"' "$DEVCONTAINER_DIR/devbox.json"
	assert_success
}

@test "starter devbox.json documents every package with a comment" {
	customize_devbox "$DEVCONTAINER_DIR"

	run grep -c '@latest.* // ' "$DEVCONTAINER_DIR/devbox.json"
	assert_output "7"
}

@test "customize_devbox keeps an existing devbox.json" {
	echo '{"packages": ["gnuplot@latest"]}' > "$DEVCONTAINER_DIR/devbox.json"

	customize_devbox "$DEVCONTAINER_DIR"

	run yq -e '.packages[0] == "gnuplot@latest"' "$DEVCONTAINER_DIR/devbox.json"
	assert_success
}

@test "customize_devbox leaves no placeholder residue" {
	customize_devbox "$DEVCONTAINER_DIR"

	run grep -c '__DEVBOX_INSTALL__' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "0"
}

@test "devcontainer always generates devbox.json and Dockerfile block" {
	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode

	run grep -c '@latest' "$PROJECT_DIR/.devcontainer/devbox.json"
	assert_output "7"
	run grep 'devbox global install' "$PROJECT_DIR/.devcontainer/Dockerfile.app"
	assert_success
	run grep -c '__DEVBOX_INSTALL__' "$PROJECT_DIR/.devcontainer/Dockerfile.app"
	assert_output "0"
}

@test "devcontainer keeps an existing devbox.json on re-init" {
	mkdir -p "$PROJECT_DIR/.devcontainer"
	echo '{"packages": ["gnuplot@latest"]}' > "$PROJECT_DIR/.devcontainer/devbox.json"

	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode

	run yq -e '.packages[0] == "gnuplot@latest"' "$PROJECT_DIR/.devcontainer/devbox.json"
	assert_success
}
