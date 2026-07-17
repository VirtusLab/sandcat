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

@test "customize_devbox enabled expands the install block" {
	customize_devbox "$DEVCONTAINER_DIR" true

	run grep 'get.jetify.com/devbox' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep 'RUN devbox global install' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep '/etc/profile.d/sandcat-devbox.sh' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "customize_devbox enabled copies the starter devbox.json" {
	customize_devbox "$DEVCONTAINER_DIR" true

	run yq -e '.packages | length == 0' "$DEVCONTAINER_DIR/devbox.json"
	assert_success
}

@test "customize_devbox keeps an existing devbox.json" {
	echo '{"packages": ["gnuplot@latest"]}' > "$DEVCONTAINER_DIR/devbox.json"

	customize_devbox "$DEVCONTAINER_DIR" true

	run yq -e '.packages[0] == "gnuplot@latest"' "$DEVCONTAINER_DIR/devbox.json"
	assert_success
}

@test "customize_devbox enabled leaves no placeholder residue" {
	customize_devbox "$DEVCONTAINER_DIR" true

	run grep -c '__DEVBOX_INSTALL__' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "0"
}

@test "customize_devbox disabled drops the placeholder and adds nothing" {
	customize_devbox "$DEVCONTAINER_DIR" false

	# -i so a leftover uppercase __DEVBOX_INSTALL__ placeholder also counts
	run grep -ci 'devbox' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "0"
	[[ ! -f "$DEVCONTAINER_DIR/devbox.json" ]]
}

@test "devcontainer --devbox generates devbox.json and Dockerfile block" {
	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode \
		--devbox

	run yq -e '.packages | length == 0' "$PROJECT_DIR/.devcontainer/devbox.json"
	assert_success
	run grep 'RUN devbox global install' "$PROJECT_DIR/.devcontainer/Dockerfile.app"
	assert_success
	run grep -c '__DEVBOX_INSTALL__' "$PROJECT_DIR/.devcontainer/Dockerfile.app"
	assert_output "0"
}

@test "devcontainer --devbox keeps an existing devbox.json on re-init" {
	mkdir -p "$PROJECT_DIR/.devcontainer"
	echo '{"packages": ["gnuplot@latest"]}' > "$PROJECT_DIR/.devcontainer/devbox.json"

	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode \
		--devbox

	run yq -e '.packages[0] == "gnuplot@latest"' "$PROJECT_DIR/.devcontainer/devbox.json"
	assert_success
}

@test "devcontainer without --devbox leaves no devbox traces" {
	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode

	[[ ! -f "$PROJECT_DIR/.devcontainer/devbox.json" ]]
	# -i so a leftover uppercase __DEVBOX_INSTALL__ placeholder also counts
	run grep -ci 'devbox' "$PROJECT_DIR/.devcontainer/Dockerfile.app"
	assert_output "0"
}
