#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# Unit tests for cli/lib/rtk.bash — the rtk feature emission helpers.

setup() {
	load ../agents/test_helper
	# shellcheck source=../../lib/rtk.bash
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK is unset (default on)" {
	unset SANDCAT_RTK
	run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK=true" {
	SANDCAT_RTK=true run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK is empty" {
	SANDCAT_RTK="" run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 1 when SANDCAT_RTK=false" {
	SANDCAT_RTK=false run sct_rtk_enabled
	assert_failure
}

@test "sct_rtk_docker_install_block emits install.sh RUN when enabled" {
	unset SANDCAT_RTK
	run sct_rtk_docker_install_block
	assert_success
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
	assert_output --partial "install.sh"
	assert_output --partial "RUN curl"
}

@test "sct_rtk_docker_install_block emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_docker_install_block
	assert_success
	assert_output ""
}
