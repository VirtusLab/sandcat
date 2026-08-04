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
