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
	assert_output --partial "RTK_INSTALL_DIR=/usr/local/bin"
	assert_output --partial "USER root"
	assert_output --partial "USER vscode"
}

@test "sct_rtk_docker_install_block emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_docker_install_block
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: claude emits guarded rtk init -g" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block claude
	assert_success
	assert_output --partial "rtk init -g"
	assert_output --partial "--hook-only"
	assert_output --partial "--auto-patch"
	assert_output --partial "command -v rtk"
	assert_output --partial "rtk hook"
	assert_output --partial "settings.json"
	assert_output --partial "non-fatal"
}

@test "sct_rtk_user_init_block: cursor emits guarded rtk init --agent cursor" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block cursor
	assert_success
	assert_output --partial "rtk init -g"
	assert_output --partial "--hook-only"
	assert_output --partial "--auto-patch"
	assert_output --partial "--agent cursor"
	assert_output --partial "command -v rtk"
	assert_output --partial "rtk hook cursor"
	assert_output --partial "hooks.json"
	# The warning message nudges users to initialise rtk on the host, which
	# is the workflow sandcat officially supports for cursor.
	assert_output --partial "on your host"
	assert_output --partial "README"
}

@test "sct_rtk_user_init_block: unknown emits nothing" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block unknown
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: claude emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_user_init_block claude
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: cursor emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_user_init_block cursor
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: codex emits nothing (rtk init is inlined in agents.bash for codex)" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block codex
	assert_success
	assert_output ""
}
