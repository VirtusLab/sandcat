# Shell installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `install.sh` at sandcat repo root — a one-liner shell installer analog to rtk/claude/cursor/codex install scripts.

**Architecture:** Single POSIX-sh-compatible bash script that fetches a tarball snapshot of the sandcat repo from `codeload.github.com/VirtusLab/sandcat/tar.gz/$SANDCAT_REF`, extracts it under `$SANDCAT_HOME` (default `$XDG_DATA_HOME/sandcat` = `~/.local/share/sandcat`), swaps atomically over any existing install via a `cli.new/` staging directory, drops a launcher symlink into `$SANDCAT_BIN_DIR` (default `~/.local/bin`), and stamps a `.version` file that sandcat's existing runtime consumes for version display. Also supports `--uninstall` for clean removal (preserves user config).

**Tech Stack:** Bash 5+, POSIX shell utilities (curl or wget fallback, tar, ln, mv, rm), bats-core + bats-mock for tests.

## Global Constraints

- Install path: `${SANDCAT_HOME:-$HOME/.local/share/sandcat}` — cli/ tree lives under this root.
- Launcher symlink: `${SANDCAT_BIN_DIR:-$HOME/.local/bin}/sandcat` → `$SANDCAT_HOME/cli/bin/sandcat`.
- Tarball source: `https://codeload.github.com/VirtusLab/sandcat/tar.gz/${SANDCAT_REF:-master}`.
- yq detection: `yq --version | grep -q mikefarah` — matches sandcat runtime's own check in `cli/lib/require.bash:25`.
- `.version` file format: `$SANDCAT_REF (installed <YYYY-MM-DD HH:MM:SS>)`, single line, written to `$SANDCAT_HOME/cli/.version`.
- Two-phase atomic swap (see Task 4): extract to `cli.new/`, rename existing to `cli.old/`, rename `cli.new/` → `cli/`, clean `cli.old/`. Guarantees the user always has a working `cli/` OR falls back to `cli.old/` on any error.
- Uninstall NEVER touches `~/.config/sandcat/`, Docker images, or docker volumes.
- Non-interactive mode: `SANDCAT_NON_INTERACTIVE=true` skips all prompts (CI-friendly).
- `set -euo pipefail` throughout; trap on ERR + EXIT cleans up `$TMP_DIR`.
- No `sandcat self-update` subcommand in this iteration (YAGNI — user re-runs install.sh for upgrade).
- Windows-native support is out of scope (WSL is the answer).

---

### Task 1: Skeleton — install.sh scaffold + `--help` + arg parsing

**Files:**
- Create: `install.sh` (repo root)
- Create: `cli/test/installer/installer.bats`
- Create: `cli/test/installer/test_helper.bash` (loads bats libraries, exports helper env)

**Interfaces:**
- Consumes: nothing (this is the foundation).
- Produces:
  - `install.sh --help` prints usage banner and exits 0.
  - `install.sh --uninstall` sets internal `UNINSTALL=true` flag then falls through to Task 5's uninstall path (a stub for now — later tasks fill in the flow).
  - `install.sh` (no args) sets `UNINSTALL=false` and falls through to the install path (also stub).
  - Env vars honored: `SANDCAT_HOME`, `SANDCAT_BIN_DIR`, `SANDCAT_REF`, `SANDCAT_NON_INTERACTIVE`, all with the defaults from Global Constraints.
  - Trap cleanup on `ERR` and `EXIT` for `TMP_DIR`.

- [ ] **Step 1: Create test helper**

Create `cli/test/installer/test_helper.bash`:

```bash
#!/bin/bash

bats_require_minimum_version 1.5.0

if shopt -s compat32 2>/dev/null; then
	export BASH_COMPAT=3.2
fi
set -uo pipefail
export SHELLOPTS

SCT_ROOT="$BATS_TEST_DIRNAME/../.."
BATS_LIB_PATH="$SCT_ROOT/support":${BATS_LIB_PATH-}

bats_load_library bats-ext
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-mock-ext

# Path to install.sh under test (relative to cli/test/installer/)
INSTALL_SH="$SCT_ROOT/../install.sh"

export SCT_ROOT INSTALL_SH
```

- [ ] **Step 2: Write failing test — `--help`**

Create `cli/test/installer/installer.bats`:

```bash
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
```

- [ ] **Step 3: Run test to verify it fails**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: FAIL with `No such file or directory: install.sh`.

- [ ] **Step 4: Create install.sh skeleton**

Create `install.sh` at repo root:

```bash
#!/usr/bin/env bash
# sandcat shell installer.
# See https://github.com/VirtusLab/sandcat for the source repository.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
#
# Env overrides:
#   SANDCAT_HOME              install root (default: ~/.local/share/sandcat)
#   SANDCAT_BIN_DIR           launcher symlink dir (default: ~/.local/bin)
#   SANDCAT_REF               branch/tag/commit to install (default: master)
#   SANDCAT_NON_INTERACTIVE   skip prompts when set to "true" (default: false)

set -euo pipefail

# --- Logging helpers ---------------------------------------------------------

info() {
	printf '[INFO] %s\n' "$1"
}

warn() {
	printf '[WARN] %s\n' "$1" >&2
}

err() {
	printf '[ERROR] %s\n' "$1" >&2
}

# --- Cleanup / traps ---------------------------------------------------------

TMP_DIR=""

cleanup() {
	if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
}

trap 'cleanup' EXIT
trap 'cleanup; exit 1' ERR

# --- Argument parsing --------------------------------------------------------

usage() {
	cat <<'EOF'
Usage: install.sh [--uninstall] [--help]

Install (or update) sandcat CLI from a GitHub tarball snapshot.

Options:
  --uninstall     Remove sandcat install and launcher symlink
                  (preserves ~/.config/sandcat/ and Docker state)
  --help          Print this help and exit

Env overrides:
  SANDCAT_HOME              install root (default: ~/.local/share/sandcat)
  SANDCAT_BIN_DIR           launcher symlink dir (default: ~/.local/bin)
  SANDCAT_REF               branch/tag/commit to install (default: master)
  SANDCAT_NON_INTERACTIVE   skip prompts when set to "true" (default: false)

Examples:
  # Install latest master
  curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh

  # Pin to a specific tag or commit
  curl -fsSL https://.../install.sh | SANDCAT_REF=v1.0.0 sh
  curl -fsSL https://.../install.sh | SANDCAT_REF=abc123 sh

  # Non-interactive (CI)
  curl -fsSL https://.../install.sh | SANDCAT_NON_INTERACTIVE=true sh

  # Uninstall
  bash <(curl -fsSL https://.../install.sh) --uninstall
EOF
}

UNINSTALL=false
while [ $# -gt 0 ]; do
	case "$1" in
		--uninstall) UNINSTALL=true; shift ;;
		--help|-h)   usage; exit 0 ;;
		*)           err "Unknown argument: $1"; usage; exit 2 ;;
	esac
done

# --- Path resolution ---------------------------------------------------------

SANDCAT_HOME="${SANDCAT_HOME:-$HOME/.local/share/sandcat}"
SANDCAT_BIN_DIR="${SANDCAT_BIN_DIR:-$HOME/.local/bin}"
SANDCAT_REF="${SANDCAT_REF:-master}"
SANDCAT_NON_INTERACTIVE="${SANDCAT_NON_INTERACTIVE:-false}"

# --- Dispatch (later tasks fill in) ------------------------------------------

if [ "$UNINSTALL" = "true" ]; then
	err "Uninstall not implemented yet (task 5)"
	exit 3
fi

err "Install not implemented yet (tasks 2-4)"
exit 3
```

- [ ] **Step 5: Run test to verify it passes**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: PASS (1/1).

- [ ] **Step 6: Commit**

```
git add install.sh cli/test/installer/installer.bats cli/test/installer/test_helper.bash
git commit -m "feat(installer): install.sh skeleton with --help and arg parsing"
```

---

### Task 2: Prerequisite check (curl/wget/tar + yq mikefarah detection)

**Files:**
- Modify: `install.sh`
- Modify: `cli/test/installer/installer.bats`

**Interfaces:**
- Consumes: `err()`, `info()`, `warn()` logging helpers from Task 1.
- Produces:
  - `check_prerequisites()` function that verifies:
    - `curl` OR `wget` present (sets internal `HTTP_CMD` variable to whichever exists — first `curl`, else `wget`)
    - `tar` present
    - `yq` present AND `yq --version` output matches `/mikefarah/`
  - On any missing/wrong prerequisite: prints per-OS install instructions to stderr and `exit 1`.
  - OS detection: `detect_os()` returns one of `macos | debian | ubuntu | alpine | linux-generic | unknown` (used to tailor yq instructions).

- [ ] **Step 1: Add failing tests to `cli/test/installer/installer.bats`**

Append at end:

```bash
@test "install.sh exits with per-OS yq instructions when yq is missing" {
	# Stub PATH so yq isn't found. bats-mock's stub isn't ideal for "make X
	# not exist"; use a bin dir that shadows real tools.
	local fake_bin="$BATS_TEST_TMPDIR/nobin"
	mkdir -p "$fake_bin"
	# Provide curl and tar (yq intentionally absent).
	ln -s "$(command -v curl)" "$fake_bin/curl"
	ln -s "$(command -v tar)" "$fake_bin/tar"

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
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: FAIL (checks not implemented; install stub message shown even when yq is missing).

- [ ] **Step 3: Add prereq check to `install.sh`**

Insert AFTER the argument-parsing block but BEFORE the dispatch stub, add:

```bash
# --- OS detection ------------------------------------------------------------

detect_os() {
	case "$(uname -s)" in
		Darwin) printf 'macos'; return ;;
		Linux)
			if [ -r /etc/os-release ]; then
				# shellcheck disable=SC1091
				. /etc/os-release
				case "${ID:-linux-generic}" in
					debian|ubuntu) printf 'debian' ;;
					alpine)        printf 'alpine' ;;
					*)             printf 'linux-generic' ;;
				esac
			else
				printf 'linux-generic'
			fi
			;;
		*) printf 'unknown' ;;
	esac
}

# --- Prerequisite check ------------------------------------------------------

print_yq_instructions() {
	local os=$1
	err "sandcat requires yq (Mike Farah's Go variant, https://github.com/mikefarah/yq)."
	err "Install with:"
	case "$os" in
		macos)
			err "  brew install yq"
			;;
		debian)
			err "  snap install yq"
			err "  (avoid 'apt install yq' — it installs the incompatible Python variant)"
			;;
		alpine)
			err "  apk add yq-go"
			;;
		*)
			err "  Download the binary from https://github.com/mikefarah/yq/releases"
			err "  and place it on your PATH."
			;;
	esac
}

HTTP_CMD=""

check_prerequisites() {
	if command -v curl >/dev/null 2>&1; then
		HTTP_CMD=curl
	elif command -v wget >/dev/null 2>&1; then
		HTTP_CMD=wget
	else
		err "Neither curl nor wget is installed. Install one and retry."
		exit 1
	fi

	if ! command -v tar >/dev/null 2>&1; then
		err "tar is required but not installed."
		exit 1
	fi

	if ! command -v yq >/dev/null 2>&1; then
		print_yq_instructions "$(detect_os)"
		exit 1
	fi

	if ! yq --version 2>&1 | grep -q mikefarah; then
		err "Found yq but it is not the Mike Farah (Go) variant."
		print_yq_instructions "$(detect_os)"
		exit 1
	fi
}
```

Then update the dispatch block to call it before falling through to the install stub:

```bash
if [ "$UNINSTALL" = "true" ]; then
	err "Uninstall not implemented yet (task 5)"
	exit 3
fi

check_prerequisites

err "Install not implemented yet (tasks 3-4)"
exit 3
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```
git add install.sh cli/test/installer/installer.bats
git commit -m "feat(installer): prerequisite check (curl/wget/tar + yq mikefarah variant)"
```

---

### Task 3: Fetch + extract tarball

**Files:**
- Modify: `install.sh`
- Modify: `cli/test/installer/installer.bats`

**Interfaces:**
- Consumes: `HTTP_CMD` (Task 2), logging helpers, path env vars (Task 1).
- Produces:
  - `fetch_tarball()` — populates `$TMP_DIR/sandcat.tar.gz`, using `curl -fsSL "$URL" -o "$TMP_DIR/sandcat.tar.gz"` or `wget -qO "$TMP_DIR/sandcat.tar.gz" "$URL"`. `$URL = https://codeload.github.com/VirtusLab/sandcat/tar.gz/$SANDCAT_REF`.
  - `extract_tarball()` — unpacks into `$TMP_DIR`, then discovers extracted `cli/` via `find "$TMP_DIR" -maxdepth 2 -type d -name cli -path '*/sandcat-*/cli'` (dir name is `sandcat-<ref-slug>` — glob because slug shape varies).
  - Sets `SOURCE_CLI_DIR` to the resolved extracted `cli/` path.
  - On curl 404 or extraction failure: prints clear error mentioning the ref, exits 1.

- [ ] **Step 1: Add failing tests to `cli/test/installer/installer.bats`**

Append at end:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: FAIL — the fetch stage doesn't emit "Fetching"/"Extracting" yet.

- [ ] **Step 3: Add fetch + extract to `install.sh`**

Insert AFTER `check_prerequisites` (still before the "not implemented" install stub) — and before that stub add TMP_DIR creation:

```bash
# --- Fetch + extract ---------------------------------------------------------

fetch_tarball() {
	local url="https://codeload.github.com/VirtusLab/sandcat/tar.gz/$SANDCAT_REF"
	info "Fetching $SANDCAT_REF from codeload.github.com..."
	local dest="$TMP_DIR/sandcat.tar.gz"
	if [ "$HTTP_CMD" = curl ]; then
		if ! curl -fsSL "$url" -o "$dest"; then
			err "Failed to fetch tarball. Reference '$SANDCAT_REF' not found in VirtusLab/sandcat (URL: $url)."
			exit 1
		fi
	else
		if ! wget -qO "$dest" "$url"; then
			err "Failed to fetch tarball. Reference '$SANDCAT_REF' not found in VirtusLab/sandcat (URL: $url)."
			exit 1
		fi
	fi
}

SOURCE_CLI_DIR=""

extract_tarball() {
	info "Extracting to $TMP_DIR..."
	if ! tar xzf "$TMP_DIR/sandcat.tar.gz" -C "$TMP_DIR"; then
		err "Failed to extract tarball."
		exit 1
	fi

	# GitHub codeload wraps the repo tree in a top-level dir named
	# sandcat-<ref-slug>. Find the extracted cli/ within.
	local found
	found=$(find "$TMP_DIR" -maxdepth 3 -type d -name cli -path '*/sandcat-*/cli' | head -n1)
	if [ -z "$found" ]; then
		err "Extracted tarball has no sandcat-*/cli/ directory. Structure unexpected."
		exit 1
	fi
	SOURCE_CLI_DIR="$found"
}
```

Update the dispatch to allocate `TMP_DIR` and call the new functions before the install stub:

```bash
if [ "$UNINSTALL" = "true" ]; then
	err "Uninstall not implemented yet (task 5)"
	exit 3
fi

check_prerequisites

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t sandcat-install)
fetch_tarball
extract_tarball

err "Install not implemented yet (task 4)"
exit 3
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: PASS (6/6).

- [ ] **Step 5: Commit**

```
git add install.sh cli/test/installer/installer.bats
git commit -m "feat(installer): fetch + extract tarball from codeload.github.com"
```

---

### Task 4: Install files (two-phase swap) + symlink + verify + PATH hint + success

**Files:**
- Modify: `install.sh`
- Modify: `cli/test/installer/installer.bats`

**Interfaces:**
- Consumes: `SOURCE_CLI_DIR`, `TMP_DIR`, path env vars, logging helpers.
- Produces:
  - `detect_existing_install()` — prompts unless `SANDCAT_NON_INTERACTIVE=true`. Returns 0 to proceed, exits 0 with a message when user declines.
  - `install_files()` — two-phase swap:
    1. `rm -rf $SANDCAT_HOME/cli.new`
    2. `mv $SOURCE_CLI_DIR $SANDCAT_HOME/cli.new`
    3. `rm -rf $SANDCAT_HOME/cli.old`
    4. If `$SANDCAT_HOME/cli` exists: `mv $SANDCAT_HOME/cli $SANDCAT_HOME/cli.old`
    5. `mv $SANDCAT_HOME/cli.new $SANDCAT_HOME/cli`
    6. `rm -rf $SANDCAT_HOME/cli.old`
    7. Write `$SANDCAT_HOME/cli/.version` with `$SANDCAT_REF (installed $(date +'%F %T'))`.
  - `install_symlink()` — `ln -sf $SANDCAT_HOME/cli/bin/sandcat $SANDCAT_BIN_DIR/sandcat`.
  - `verify_install()` — runs `$SANDCAT_BIN_DIR/sandcat version >/dev/null 2>&1`; exits 1 with clear message on failure.
  - `print_success()` — prints installed ref, install dir, symlink, PATH hint if `$SANDCAT_BIN_DIR` not in `$PATH`.

- [ ] **Step 1: Add failing tests to `cli/test/installer/installer.bats`**

Append at end:

```bash
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

	# Symlink present and resolves back to the install path
	[ -L "$sandcat_bin/sandcat" ]
	local target
	target=$(readlink -f "$sandcat_bin/sandcat")
	[ "$target" = "$sandcat_home/cli/bin/sandcat" ]
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: FAIL — install stub still exits 3.

- [ ] **Step 3: Add install/symlink/verify/success stages to `install.sh`**

Insert AFTER `extract_tarball()`:

```bash
# --- Install files (two-phase swap) ------------------------------------------

prompt_yes_no() {
	local msg=$1
	if [ "$SANDCAT_NON_INTERACTIVE" = "true" ]; then
		return 0
	fi
	printf '%s [y/N]: ' "$msg" >&2
	local reply
	IFS= read -r reply || reply=""
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*)           return 1 ;;
	esac
}

detect_existing_install() {
	if [ -d "$SANDCAT_HOME/cli" ]; then
		if ! prompt_yes_no "Sandcat is already installed at $SANDCAT_HOME/cli. Overwrite?"; then
			info "Aborted — existing install preserved."
			exit 0
		fi
	fi

	# Guard rare case: SANDCAT_HOME itself exists as a file, not a directory.
	if [ -e "$SANDCAT_HOME" ] && [ ! -d "$SANDCAT_HOME" ]; then
		err "$SANDCAT_HOME already exists as a file, not a directory. Move it and retry."
		exit 1
	fi
}

install_files() {
	mkdir -p "$SANDCAT_HOME"

	# Two-phase swap. Guarantees that the user's existing cli/ is only
	# replaced by a rename(2), and that on any earlier failure the old
	# tree remains intact.
	rm -rf "$SANDCAT_HOME/cli.new"
	mv "$SOURCE_CLI_DIR" "$SANDCAT_HOME/cli.new"

	rm -rf "$SANDCAT_HOME/cli.old"
	if [ -d "$SANDCAT_HOME/cli" ]; then
		mv "$SANDCAT_HOME/cli" "$SANDCAT_HOME/cli.old"
	fi
	mv "$SANDCAT_HOME/cli.new" "$SANDCAT_HOME/cli"
	rm -rf "$SANDCAT_HOME/cli.old"

	printf '%s (installed %s)\n' "$SANDCAT_REF" "$(date +'%F %T')" \
		> "$SANDCAT_HOME/cli/.version"

	info "Installed sandcat $SANDCAT_REF to $SANDCAT_HOME/cli/"
}

install_symlink() {
	mkdir -p "$SANDCAT_BIN_DIR"
	# Warn (but proceed) if the launcher path is a non-symlink file — user
	# may have another script there. ln -sf will overwrite regardless.
	if [ -e "$SANDCAT_BIN_DIR/sandcat" ] && [ ! -L "$SANDCAT_BIN_DIR/sandcat" ]; then
		warn "Replacing existing non-symlink file at $SANDCAT_BIN_DIR/sandcat"
	fi
	ln -sf "$SANDCAT_HOME/cli/bin/sandcat" "$SANDCAT_BIN_DIR/sandcat"
	info "Symlinked $SANDCAT_BIN_DIR/sandcat -> $SANDCAT_HOME/cli/bin/sandcat"
}

verify_install() {
	if ! "$SANDCAT_BIN_DIR/sandcat" version >/dev/null 2>&1; then
		err "Verification failed: '$SANDCAT_BIN_DIR/sandcat version' did not run cleanly."
		exit 1
	fi
}

path_contains() {
	# Portable "is $1 present in colon-separated PATH?"
	case ":$PATH:" in
		*":$1:"*) return 0 ;;
		*)        return 1 ;;
	esac
}

print_success() {
	info "sandcat $SANDCAT_REF installed."
	info ""
	info "Next steps:"
	if ! path_contains "$SANDCAT_BIN_DIR"; then
		info "  Add $SANDCAT_BIN_DIR to your PATH (append to ~/.bashrc or ~/.zshrc):"
		info "    export PATH=\"$SANDCAT_BIN_DIR:\$PATH\""
	fi
	info "  Then in your project directory: sandcat init"
}
```

Replace the "install not implemented" stub with the real dispatch:

```bash
if [ "$UNINSTALL" = "true" ]; then
	err "Uninstall not implemented yet (task 5)"
	exit 3
fi

check_prerequisites

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t sandcat-install)
detect_existing_install
fetch_tarball
extract_tarball
install_files
install_symlink
verify_install
print_success
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: PASS (9/9).

- [ ] **Step 5: Commit**

```
git add install.sh cli/test/installer/installer.bats
git commit -m "feat(installer): install files with two-phase swap + symlink + verify"
```

---

### Task 5: `--uninstall` flow

**Files:**
- Modify: `install.sh`
- Modify: `cli/test/installer/installer.bats`

**Interfaces:**
- Consumes: path env vars, logging helpers, `prompt_yes_no()` (Task 4).
- Produces:
  - `uninstall()` — removes `$SANDCAT_BIN_DIR/sandcat` symlink and `$SANDCAT_HOME/cli/`, prompts unless `SANDCAT_NON_INTERACTIVE=true`. Removes `$SANDCAT_HOME` only if empty. Preserves user config and Docker state.
  - Exits 0 with informational message when nothing is installed.

- [ ] **Step 1: Add failing tests to `cli/test/installer/installer.bats`**

Append at end:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: FAIL — uninstall stub still exits 3.

- [ ] **Step 3: Implement uninstall in `install.sh`**

Insert AFTER `print_success()`:

```bash
# --- Uninstall ---------------------------------------------------------------

uninstall() {
	if [ ! -d "$SANDCAT_HOME/cli" ] && [ ! -L "$SANDCAT_BIN_DIR/sandcat" ]; then
		info "Sandcat is not installed at $SANDCAT_HOME (nothing to remove)."
		return 0
	fi

	if ! prompt_yes_no "Remove sandcat install at $SANDCAT_HOME/cli/ and launcher at $SANDCAT_BIN_DIR/sandcat?"; then
		info "Aborted — install preserved."
		return 0
	fi

	rm -f "$SANDCAT_BIN_DIR/sandcat"
	rm -rf "$SANDCAT_HOME/cli"
	# Also sweep any stale swap dirs from an aborted install.
	rm -rf "$SANDCAT_HOME/cli.new" "$SANDCAT_HOME/cli.old"

	if [ -d "$SANDCAT_HOME" ] && [ -z "$(ls -A "$SANDCAT_HOME" 2>/dev/null)" ]; then
		rmdir "$SANDCAT_HOME"
	fi

	info "Removed sandcat install ($SANDCAT_HOME/cli/) and launcher ($SANDCAT_BIN_DIR/sandcat)."
	info "User settings preserved at ~/.config/sandcat/ (delete manually if desired)."
	info "Docker images and cache volumes untouched. Use 'sandcat cache rm --all' or 'docker rmi' if wanted."
}
```

Replace the uninstall stub at the top of the dispatch:

```bash
if [ "$UNINSTALL" = "true" ]; then
	uninstall
	exit 0
fi

check_prerequisites
# ... rest of install path ...
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd cli && ./run-tests.bash test/installer/installer.bats
```

Expected: PASS (12/12).

- [ ] **Step 5: Run the full suite to confirm no regressions**

```
cd cli && ./run-tests.bash
```

Expected: PASS (all existing agents/init/rtk/etc. tests green + new installer suite).

- [ ] **Step 6: Commit**

```
git add install.sh cli/test/installer/installer.bats
git commit -m "feat(installer): --uninstall flow (preserves user config + docker state)"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (repo root)
- Modify: `cli/README.md`

**Interfaces:** None — pure documentation.

- [ ] **Step 1: Add "Shell installer" subsection to `README.md`**

Locate the "### 1. Install sandcat CLI" section in `README.md`. Between the "Run as docker image" and "Local install" subsections, insert:

```markdown
#### Shell installer

Install sandcat CLI to `~/.local/share/sandcat/` with a launcher symlink
at `~/.local/bin/sandcat`. Requires `yq` (Mike Farah's Go variant) already
installed on the host.

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
```

Version pinning via `SANDCAT_REF` (branch / tag / commit):

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | SANDCAT_REF=v1.0.0 sh
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | SANDCAT_REF=abc123 sh
```

Custom paths (env overrides):

```bash
SANDCAT_HOME=/opt/sandcat SANDCAT_BIN_DIR=/usr/local/bin \
    curl -fsSL https://.../install.sh | sudo -E sh   # system-wide
```

Non-interactive mode (CI):

```bash
curl -fsSL https://.../install.sh | SANDCAT_NON_INTERACTIVE=true sh
```

Upgrade: re-run the installer with the same (or a different) `SANDCAT_REF`. Existing
install is swapped atomically; `~/.config/sandcat/` is never touched.

Uninstall (preserves user config and Docker state):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh) --uninstall
```

Env overrides in one place:

| Var | Default | Purpose |
|---|---|---|
| `SANDCAT_HOME` | `$HOME/.local/share/sandcat` | Install root |
| `SANDCAT_BIN_DIR` | `$HOME/.local/bin` | Launcher symlink dir |
| `SANDCAT_REF` | `master` | Branch / tag / commit to fetch |
| `SANDCAT_NON_INTERACTIVE` | `false` | Skip all prompts (CI) |
```

- [ ] **Step 2: Cross-link from `cli/README.md`**

Locate the top of `cli/README.md`. Add a paragraph near the top pointing at the shell installer as one of three install options:

```markdown
See the top-level [README](../README.md#1-install-sandcat-cli) for install
options: Docker image, shell installer (`curl … | sh`), or local git
clone.
```

Merge this with existing intro paragraph if one exists — don't duplicate.

- [ ] **Step 3: Commit**

```
git add README.md cli/README.md
git commit -m "docs: shell installer (README + cli/README cross-link)"
```

---

### Task 7: Hands-on integration verification

**Files:** None (manual verification; results reported to the user)

**Interfaces:** None.

Each scenario runs against real filesystem paths (no bats mocks). Use scratch dirs under `/tmp/sandcat-installer-integ.XXXX` so real `$HOME` is untouched.

- [ ] **Scenario 1 — Fresh install to scratch paths**

```bash
TEST_ROOT=$(mktemp -d /tmp/sandcat-installer-integ.XXXX)
SANDCAT_HOME="$TEST_ROOT/home/.local/share/sandcat" \
SANDCAT_BIN_DIR="$TEST_ROOT/home/.local/bin" \
SANDCAT_NON_INTERACTIVE=true \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh

# Verify
ls -la "$SANDCAT_HOME/cli/"       # -> bin/ lib/ libexec/ templates/ .version
ls -la "$SANDCAT_BIN_DIR/sandcat" # -> symlink
readlink -f "$SANDCAT_BIN_DIR/sandcat"
"$SANDCAT_BIN_DIR/sandcat" version
```

Expected: cli tree present; symlink resolves back to `$SANDCAT_HOME/cli/bin/sandcat`; `sandcat version` prints `Sandcat master (installed <timestamp>)`.

- [ ] **Scenario 2 — Version pinning by commit**

```bash
# Use a recent commit SHA from origin/master
COMMIT=$(git -C /Users/seweryn.hejnowicz/projects/sandcat rev-parse origin/master^)
SANDCAT_HOME="$TEST_ROOT/home2/.local/share/sandcat" \
SANDCAT_BIN_DIR="$TEST_ROOT/home2/.local/bin" \
SANDCAT_NON_INTERACTIVE=true \
SANDCAT_REF="$COMMIT" \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh

cat "$SANDCAT_HOME/cli/.version"
```

Expected: `.version` file contains the commit SHA and install timestamp.

- [ ] **Scenario 3 — Upgrade path (re-run overwrites cleanly)**

```bash
# Simulate an old install by seeding a marker
echo "old marker" > "$SANDCAT_HOME/cli/OLD_MARKER"

SANDCAT_HOME="$SANDCAT_HOME" \
SANDCAT_BIN_DIR="$SANDCAT_BIN_DIR" \
SANDCAT_NON_INTERACTIVE=true \
SANDCAT_REF=master \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh

[ ! -f "$SANDCAT_HOME/cli/OLD_MARKER" ] && echo "old wiped as expected"
[ ! -d "$SANDCAT_HOME/cli.new" ] && [ ! -d "$SANDCAT_HOME/cli.old" ] && echo "swap dirs cleaned"
```

Expected: OLD_MARKER gone, no stale swap dirs, new install intact.

- [ ] **Scenario 4 — Bad SANDCAT_REF (404)**

```bash
SANDCAT_HOME="$TEST_ROOT/home-bad/.local/share/sandcat" \
SANDCAT_BIN_DIR="$TEST_ROOT/home-bad/.local/bin" \
SANDCAT_NON_INTERACTIVE=true \
SANDCAT_REF=bogusref \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh
```

Expected: exit 1 with `[ERROR] Failed to fetch tarball. Reference 'bogusref' not found …`. No files landed in `$SANDCAT_HOME`.

- [ ] **Scenario 5 — Uninstall**

```bash
SANDCAT_HOME="$TEST_ROOT/home/.local/share/sandcat" \
SANDCAT_BIN_DIR="$TEST_ROOT/home/.local/bin" \
SANDCAT_NON_INTERACTIVE=true \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh --uninstall

[ ! -d "$SANDCAT_HOME" ] && echo "install dir removed"
[ ! -L "$SANDCAT_BIN_DIR/sandcat" ] && echo "launcher removed"
```

Expected: install dir + launcher gone. `~/.config/sandcat/` (if it existed on the real host) untouched.

- [ ] **Scenario 6 — PATH hint when SANDCAT_BIN_DIR not on PATH**

```bash
SANDCAT_HOME="$TEST_ROOT/home3/.local/share/sandcat" \
SANDCAT_BIN_DIR="$TEST_ROOT/home3/.local/bin" \
SANDCAT_NON_INTERACTIVE=true \
PATH=/usr/bin:/bin \
    bash /Users/seweryn.hejnowicz/projects/sandcat/install.sh
```

Expected: install succeeds, output includes `[INFO] Add $TEST_ROOT/home3/.local/bin to your PATH …`.

- [ ] **Scenario 7 — Cleanup**

```bash
rm -rf "$TEST_ROOT"
```

- [ ] **If all 6 scenarios pass, no commit needed.** If any scenario fails, DO NOT proceed to the PR. Fix in the task whose deliverable caused the failure.

---

## Post-implementation

After Task 7 succeeds:

1. Rebase onto latest `origin/master` if needed.
2. Run the full unit test suite one final time: `cd cli && ./run-tests.bash`.
3. Per project preference (memory `feedback-exclude-sdd-docs-from-prs`), `git rm` the design spec and this plan doc before opening the PR:

   ```
   git rm docs/superpowers/specs/2026-08-04-shell-installer-design.md
   git rm docs/superpowers/plans/2026-08-04-shell-installer.md
   git commit -m "chore: remove SDD spec + plan docs from branch"
   ```

4. Push and open a PR — title `feat(cli): shell installer (issue #30)`. Body follows the PR#87 (codex) format: Summary / Design notes / Test plan with all 7 integration scenarios marked done.
