#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../lib/path.bash
	source "$SCT_LIBDIR/path.bash"
}

teardown() {
	unstub_all
}

@test "finds compose file in .devcontainer" {
	local test_root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$test_root/.devcontainer"
	mkdir -p "$test_root/.git"
	touch "$test_root/.devcontainer/compose-all.yml"

	cd "$test_root"
	run find_compose_file
	assert_success
	assert_output "$test_root/.devcontainer/compose-all.yml"
}

@test "fails when no compose file exists" {
	local test_root="$BATS_TEST_TMPDIR/repo"

	mkdir -p "$test_root/$SCT_PROJECT_DIR"
	mkdir -p "$test_root/.devcontainer"
	mkdir -p "$test_root/.git"

	cd "$test_root"
	run find_compose_file
	assert_failure
	assert_output --partial "No compose-all.yml found"
}

@test "works from nested directory" {
	local test_root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$test_root/.devcontainer"
	mkdir -p "$test_root/.git"
	mkdir -p "$test_root/nested/deep"
	touch "$test_root/.devcontainer/compose-all.yml"

	cd "$test_root/nested/deep"
	run find_compose_file
	assert_success
	assert_output "$test_root/.devcontainer/compose-all.yml"
}

@test "fails when repo root not found" {
	cd "$BATS_TEST_TMPDIR"
	run find_compose_file
	assert_failure
	assert_output --partial "repository root not found"
}
