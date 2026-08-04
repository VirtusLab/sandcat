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
				local distro_id
				# shellcheck disable=SC1091
				distro_id=$(. /etc/os-release && printf '%s' "${ID:-linux-generic}")
				case "$distro_id" in
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

# --- Root-user warning -------------------------------------------------------

should_warn_root() {
	local uid=$1
	local sandcat_home=$2
	[ "$uid" = "0" ] || return 1
	case "$sandcat_home" in
		/root/*) return 0 ;;
		*)       return 1 ;;
	esac
}

warn_if_root_without_overrides() {
	if should_warn_root "$(id -u)" "$SANDCAT_HOME"; then
		warn "Running as root: sandcat will be installed under /root/. Set SANDCAT_HOME and SANDCAT_BIN_DIR for a system-wide install (e.g. SANDCAT_HOME=/opt/sandcat SANDCAT_BIN_DIR=/usr/local/bin)."
	fi
}

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

# --- Dispatch ----------------------------------------------------------------

if [ "$UNINSTALL" = "true" ]; then
	uninstall
	exit 0
fi

check_prerequisites
warn_if_root_without_overrides

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t sandcat-install)
detect_existing_install
fetch_tarball
extract_tarball
install_files
install_symlink
verify_install
print_success
