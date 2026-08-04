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

# --- Dispatch (later tasks fill in) ------------------------------------------

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
