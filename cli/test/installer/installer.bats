#!/usr/bin/env bats

setup() {
	load test_helper
	# Isolate HOME
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
}

@test "install.sh --help prints usage and exits 0" {
	run bash "$INSTALL_SH" --help
	assert_success
	assert_output --partial "Usage:"
	assert_output --partial "SANDCAT_HOME"
	assert_output --partial "SANDCAT_REF"
	assert_output --partial "--uninstall"
}
