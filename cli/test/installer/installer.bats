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

# Helper: builds a fake sandcat tarball (structure matches what
# codeload.github.com produces: sandcat-<ref>/cli/...) and stubs curl
# to serve it. Sets FIXTURE_TARBALL and installs a PATH override.
_stub_curl_with_fixture() {
	local ref="${1:-master}"
	local fixture_root="$BATS_TEST_TMPDIR/fixture"
	local wrapper_dir="$fixture_root/sandcat-$ref"

	mkdir -p "$wrapper_dir/cli/bin"
	mkdir -p "$wrapper_dir/cli/lib"
	mkdir -p "$wrapper_dir/cli/libexec/version"
	mkdir -p "$wrapper_dir/cli/templates"

	# Minimal sandcat launcher that echoes its own path (proves the symlink
	# actually resolves back through readlink -f).
	cat > "$wrapper_dir/cli/bin/sandcat" <<'FAKESAND'
#!/usr/bin/env bash
if [ "${1-}" = "version" ]; then
	echo "fake sandcat version"
	exit 0
fi
exit 0
FAKESAND
	chmod +x "$wrapper_dir/cli/bin/sandcat"

	FIXTURE_TARBALL="$BATS_TEST_TMPDIR/fixture.tar.gz"
	tar czf "$FIXTURE_TARBALL" -C "$fixture_root" "sandcat-$ref"

	# Fake curl on PATH that writes the fixture to whatever -o path is given.
	local fake_bin="$BATS_TEST_TMPDIR/nobin"
	mkdir -p "$fake_bin"
	cat > "$fake_bin/curl" <<FAKECURL
#!/bin/bash
# Understand -f -s -S -L and -o <path>.
out=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o) out=\$2; shift 2 ;;
		-fsSL|-f|-s|-S|-L) shift ;;
		http*) url=\$1; shift ;;
		*) shift ;;
	esac
done
if [ -z "\$out" ]; then
	exit 22
fi
# Test 404 branch: URL contains 'bogusref'.
if [[ "\$url" == *bogusref* ]]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
cp "$FIXTURE_TARBALL" "\$out"
FAKECURL
	chmod +x "$fake_bin/curl"
	ln -sf "$(command -v tar)" "$fake_bin/tar"
	ln -sf "$(command -v mktemp)" "$fake_bin/mktemp"
	ln -sf "$(command -v bash)" "$fake_bin/bash"
	ln -sf "$(command -v sh)" "$fake_bin/sh"
	ln -sf "$(command -v cat)" "$fake_bin/cat"
	ln -sf "$(command -v rm)" "$fake_bin/rm"
	ln -sf "$(command -v grep)" "$fake_bin/grep"
	ln -sf "$(command -v uname)" "$fake_bin/uname"
	ln -sf "$(command -v cp)" "$fake_bin/cp"
	cat > "$fake_bin/yq" <<'FAKEYQ'
#!/bin/bash
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq) version v4.44.3"
	exit 0
fi
exit 0
FAKEYQ
	chmod +x "$fake_bin/yq"

	FAKE_BIN="$fake_bin"
}

@test "install.sh fetches + extracts tarball into TMP_DIR" {
	_stub_curl_with_fixture master

	# For this task we cover fetch + extract only; the install-files step
	# is Task 4 and will still fail (the stub echo). Assert output shows
	# the fetch + extraction succeeded before the stub error.
	SANDCAT_HOME="$BATS_TEST_TMPDIR/home/.local/share/sandcat" \
	SANDCAT_BIN_DIR="$BATS_TEST_TMPDIR/home/.local/bin" \
	SANDCAT_REF=master \
	PATH="$FAKE_BIN" run bash "$INSTALL_SH"

	# fetch + extract stages should have logged their [INFO]s before we hit
	# the "install-files not implemented" stub from Task 3 flow.
	assert_output --partial "Fetching"
	assert_output --partial "Extracting"
}

@test "install.sh fails with clear error on 404 SANDCAT_REF" {
	_stub_curl_with_fixture bogusref

	SANDCAT_HOME="$BATS_TEST_TMPDIR/home/.local/share/sandcat" \
	SANDCAT_BIN_DIR="$BATS_TEST_TMPDIR/home/.local/bin" \
	SANDCAT_REF=bogusref \
	PATH="$FAKE_BIN" run bash "$INSTALL_SH"

	assert_failure
	assert_output --partial "bogusref"
	assert_output --partial "not found"
}
