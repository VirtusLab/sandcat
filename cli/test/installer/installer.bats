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

@test "install.sh exits with per-OS yq instructions when yq is missing" {
	# Stub PATH so yq isn't found. bats-mock's stub isn't ideal for "make X
	# not exist"; use a bin dir that shadows real tools.
	local fake_bin="$BATS_TEST_TMPDIR/nobin"
	mkdir -p "$fake_bin"
	# Provide curl and tar (yq intentionally absent).
	ln -s "$(command -v curl)" "$fake_bin/curl"
	ln -s "$(command -v tar)" "$fake_bin/tar"
	# Also need basic tools for the shell and mktemp (for bats run).
	ln -s "$(command -v bash)" "$fake_bin/bash"
	ln -s "$(command -v sh)" "$fake_bin/sh"
	ln -s "$(command -v mktemp)" "$fake_bin/mktemp"
	ln -s "$(command -v cat)" "$fake_bin/cat"
	ln -s "$(command -v rm)" "$fake_bin/rm"

	PATH="$fake_bin" run bash "$INSTALL_SH"
	assert_failure
	assert_output --partial "yq"
	assert_output --partial "mikefarah"
}

@test "install.sh exits when yq is wrong variant (Python yq)" {
	local fake_bin="$BATS_TEST_TMPDIR/nobin"
	mkdir -p "$fake_bin"
	ln -s "$(command -v curl)" "$fake_bin/curl"
	ln -s "$(command -v tar)" "$fake_bin/tar"
	ln -s "$(command -v bash)" "$fake_bin/bash"
	ln -s "$(command -v sh)" "$fake_bin/sh"
	ln -s "$(command -v mktemp)" "$fake_bin/mktemp"
	ln -s "$(command -v cat)" "$fake_bin/cat"
	ln -s "$(command -v rm)" "$fake_bin/rm"

	# Fake yq that reports Python-variant version.
	cat > "$fake_bin/yq" <<'FAKE'
#!/bin/bash
if [[ "${1-}" == "--version" ]]; then
	echo "yq 3.4.3 (Python yq — kislyuk/yq)"
	exit 0
fi
exit 0
FAKE
	chmod +x "$fake_bin/yq"

	PATH="$fake_bin" run bash "$INSTALL_SH"
	assert_failure
	assert_output --partial "mikefarah"
}

@test "install.sh accepts curl-based fetch when curl available" {
	# Prereq check should not complain about HTTP tool when curl exists.
	# The install still fails later (task 3 not implemented), but the
	# error should be from the install path, not the prereq step.
	local fake_bin="$BATS_TEST_TMPDIR/nobin"
	mkdir -p "$fake_bin"
	ln -s "$(command -v curl)" "$fake_bin/curl"
	ln -s "$(command -v tar)" "$fake_bin/tar"
	ln -s "$(command -v bash)" "$fake_bin/bash"
	ln -s "$(command -v sh)" "$fake_bin/sh"
	ln -s "$(command -v mktemp)" "$fake_bin/mktemp"
	ln -s "$(command -v cat)" "$fake_bin/cat"
	ln -s "$(command -v rm)" "$fake_bin/rm"
	ln -s "$(command -v grep)" "$fake_bin/grep"
	ln -s "$(command -v uname)" "$fake_bin/uname"
	cat > "$fake_bin/yq" <<'FAKE'
#!/bin/bash
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq) version v4.44.3"
	exit 0
fi
exit 0
FAKE
	chmod +x "$fake_bin/yq"

	PATH="$fake_bin" run bash "$INSTALL_SH"
	# Task 3 not implemented yet → fails with the stub error, NOT the yq one.
	assert_failure
	refute_output --partial "mikefarah"
	refute_output --partial "yq"
}
