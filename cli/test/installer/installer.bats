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

# Helper: like _stub_curl_with_fixture but puts a fake wget on PATH and
# deliberately omits curl so the installer takes the wget branch.
_stub_wget_with_fixture() {
	local ref="${1:-master}"
	local fixture_root="$BATS_TEST_TMPDIR/fixture-wget"
	local wrapper_dir="$fixture_root/sandcat-$ref"

	mkdir -p "$wrapper_dir/cli/bin"
	mkdir -p "$wrapper_dir/cli/lib"
	mkdir -p "$wrapper_dir/cli/libexec/version"
	mkdir -p "$wrapper_dir/cli/templates"
	cat > "$wrapper_dir/cli/bin/sandcat" <<'FAKESAND'
#!/usr/bin/env bash
if [ "${1-}" = "version" ]; then
    echo "fake sandcat version"
    exit 0
fi
exit 0
FAKESAND
	chmod +x "$wrapper_dir/cli/bin/sandcat"

	FIXTURE_TARBALL_WGET="$BATS_TEST_TMPDIR/fixture-wget.tar.gz"
	tar czf "$FIXTURE_TARBALL_WGET" -C "$fixture_root" "sandcat-$ref"

	local fake_bin="$BATS_TEST_TMPDIR/nobin-wget"
	mkdir -p "$fake_bin"
	# wget only — curl deliberately absent so installer takes the wget branch.
	cat > "$fake_bin/wget" <<FAKEWGET
#!/bin/bash
# Understand -q -O <path> <url>.
out=""
url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -qO) out=\$2; shift 2 ;;
        -O)  out=\$2; shift 2 ;;
        -q)  shift ;;
        http*) url=\$1; shift ;;
        *) shift ;;
    esac
done
if [ -z "\$out" ]; then
    exit 8
fi
if [[ "\$url" == *bogusref* ]]; then
    echo "wget: server returned error: HTTP/1.1 404 Not Found" >&2
    exit 8
fi
cp "$FIXTURE_TARBALL_WGET" "\$out"
FAKEWGET
	chmod +x "$fake_bin/wget"
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
	FAKE_BIN_WGET="$fake_bin"
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

@test "install.sh installs cli/ under SANDCAT_HOME with symlink in SANDCAT_BIN_DIR" {
	_stub_curl_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_REF=master \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH"
	assert_success

	# Files landed under SANDCAT_HOME/cli/
	[ -d "$sandcat_home/cli/bin" ]
	[ -x "$sandcat_home/cli/bin/sandcat" ]
	[ -d "$sandcat_home/cli/lib" ]
	[ -d "$sandcat_home/cli/templates" ]

	# .version file written with SANDCAT_REF and a timestamp
	[ -s "$sandcat_home/cli/.version" ]
	run cat "$sandcat_home/cli/.version"
	assert_output --partial "master"
	assert_output --partial "installed"

	# Symlink present and resolves back to the install path.
	# Use readlink -f on both sides so macOS /var→/private/var symlinks
	# do not cause a spurious mismatch.
	[ -L "$sandcat_bin/sandcat" ]
	local target expected
	target=$(readlink -f "$sandcat_bin/sandcat")
	expected=$(readlink -f "$sandcat_home/cli/bin/sandcat")
	[ "$target" = "$expected" ]
}

@test "install.sh warns when SANDCAT_BIN_DIR is not on PATH" {
	_stub_curl_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	# Deliberately exclude sandcat_bin from PATH (only FAKE_BIN + system defaults).
	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_REF=master \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:/usr/bin:/bin" run bash "$INSTALL_SH"

	assert_success
	assert_output --partial "PATH"
	assert_output --partial "$sandcat_bin"
}

@test "install.sh replaces an existing install cleanly (two-phase swap)" {
	_stub_curl_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	# Pre-seed an existing install with a distinctive marker file.
	mkdir -p "$sandcat_home/cli/bin"
	echo "old marker" > "$sandcat_home/cli/OLD_MARKER"

	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_REF=master \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH"
	assert_success

	# Old marker is gone (fresh cli/ overwrote), and cli.old/ was cleaned up.
	[ ! -f "$sandcat_home/cli/OLD_MARKER" ]
	[ ! -d "$sandcat_home/cli.old" ]
	[ ! -d "$sandcat_home/cli.new" ]
	# New install has the expected shape.
	[ -x "$sandcat_home/cli/bin/sandcat" ]
}

@test "install.sh --uninstall removes install and symlink but preserves ~/.config/sandcat/" {
	_stub_curl_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"
	local user_config="$HOME/.config/sandcat"

	# First: install
	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH"
	assert_success

	# Seed a fake user config file to prove we don't touch it.
	mkdir -p "$user_config"
	echo '{"env":{}}' > "$user_config/settings.json"

	# Then: uninstall
	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH" --uninstall
	assert_success

	# Install artefacts gone
	[ ! -d "$sandcat_home/cli" ]
	[ ! -L "$sandcat_bin/sandcat" ]
	# User config preserved
	[ -f "$user_config/settings.json" ]
}

@test "install.sh --uninstall on missing install exits 0 with informational message" {
	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	# Nothing installed. Provide fake prerequisites to satisfy any checks
	# uninstall does (only path resolution; no prereq check needed for --uninstall).
	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_NON_INTERACTIVE=true \
	run bash "$INSTALL_SH" --uninstall
	assert_success
	assert_output --partial "not installed"
}

@test "install.sh uses wget fallback when curl is absent" {
	_stub_wget_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_REF=master \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN_WGET:$PATH" run bash "$INSTALL_SH"
	assert_success

	[ -x "$sandcat_home/cli/bin/sandcat" ]
	[ -L "$sandcat_bin/sandcat" ]
}

@test "install.sh warns when running as root with default /root/ paths" {
	_stub_curl_with_fixture master

	cat > "$FAKE_BIN/id" <<'FAKEID'
#!/bin/bash
if [[ "$1" == "-u" ]]; then
    echo 0; exit 0
fi
exec /usr/bin/id "$@"
FAKEID
	chmod +x "$FAKE_BIN/id"

	# SANDCAT_HOME under /root/ so the heuristic triggers.
	# The install will fail on mkdir /root/... (no perms) — that's fine,
	# we assert the warning appears in the output first.
	SANDCAT_HOME=/root/.local/share/sandcat \
	SANDCAT_BIN_DIR=/root/.local/bin \
	SANDCAT_REF=master \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH"

	# We don't assert success or failure of the install itself — only that
	# the warn message was emitted.
	assert_output --partial "Running as root"
	assert_output --partial "SANDCAT_HOME"
}

@test "install.sh --uninstall removes empty SANDCAT_HOME parent dir" {
	_stub_curl_with_fixture master

	local sandcat_home="$BATS_TEST_TMPDIR/home/.local/share/sandcat"
	local sandcat_bin="$BATS_TEST_TMPDIR/home/.local/bin"

	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH"
	assert_success

	SANDCAT_HOME="$sandcat_home" \
	SANDCAT_BIN_DIR="$sandcat_bin" \
	SANDCAT_NON_INTERACTIVE=true \
	PATH="$FAKE_BIN:$PATH" run bash "$INSTALL_SH" --uninstall
	assert_success

	# SANDCAT_HOME dir removed since it was empty after cli/ deletion
	[ ! -d "$sandcat_home" ]
}
