#!/usr/bin/env bash
# Host-side helper for Dev Containers initializeCommand.
# Cursor/VS Code run this with a GUI PATH (often no sandcat, yq, or Homebrew).
# This script must not fail the reopen: create cache volumes from local
# compose YAML, refresh the filtered .sandcat copy when the CLI is
# available, otherwise keep the .env sandcat init already wrote.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

log="$root/.devcontainer/sandcat/initializeCommand.log"
mkdir -p "$(dirname "$log")"
# Not named _log: sourcing cli/lib/logging.bash would redefine it and the
# next one-argument call dies under set -u (`$2: unbound variable`).
_sct_init_log() { echo "prepare-agent-sandcat-mount: $*" | tee -a "$log" >&2; }

# Cursor/VS Code GUI PATH often lacks Homebrew, ~/.local/bin, and Docker Desktop.
PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.nix-profile/bin:/Applications/Docker.app/Contents/Resources/bin:${PATH:-}"
export PATH

_sct_realpath() {
	local target=$1 dir
	if command -v realpath >/dev/null 2>&1; then
		realpath "$target"
		return
	fi
	if dir=$(readlink -f "$target" 2>/dev/null) && [[ -n "$dir" ]]; then
		printf '%s\n' "$dir"
		return
	fi
	while [[ -L "$target" ]]; do
		dir=$(dirname "$target")
		target=$(readlink "$target")
		[[ "$target" == /* ]] || target="$dir/$target"
	done
	dir=$(cd "$(dirname "$target")" && pwd)
	printf '%s/%s\n' "$dir" "$(basename "$target")"
}

# Create sandcat-cache-* volumes declared in local compose files. Does not
# source the CLI (GUI PATH may not have it).
_create_cache_volumes() {
	command -v docker >/dev/null 2>&1 || {
		_sct_init_log "docker not on PATH; skip cache volume create"
		return 0
	}
	local f name seen=$'\n'
	for f in \
		"$root/.devcontainer/compose-all.yml" \
		"$root/.devcontainer/sandcat/compose-agent.yml"
	do
		[[ -f "$f" ]] || continue
		while IFS= read -r name; do
			[[ -n "$name" ]] || continue
			case "$seen" in
			*$'\n'"$name"$'\n'*) continue ;;
			esac
			seen+="$name"$'\n'
			_sct_init_log "docker volume create $name"
			docker volume create --label sandcat-shared-cache=true "$name" >/dev/null 2>&1 || \
				_sct_init_log "warning: volume create $name failed"
		done < <(grep -E '^[[:space:]]+sandcat-cache-[A-Za-z0-9_-]+:[[:space:]]*$' "$f" \
			| sed -E 's/^[[:space:]]+//; s/:[[:space:]]*$//' || true)
	done
}

_find_sct_libdir() {
	if [[ -n "${SCT_LIBDIR:-}" && -f "${SCT_LIBDIR}/netbird.bash" ]]; then
		printf '%s\n' "$SCT_LIBDIR"
		return 0
	fi
	local bin
	bin=$(command -v sandcat 2>/dev/null || true)
	if [[ -z "$bin" && -x "${HOME}/.local/bin/sandcat" ]]; then
		bin="${HOME}/.local/bin/sandcat"
	fi
	[[ -n "$bin" ]] || return 1
	bin=$(_sct_realpath "$bin")
	local lib
	lib=$(cd "$(dirname "$bin")/../lib" && pwd)
	[[ -f "$lib/netbird.bash" ]] || return 1
	printf '%s\n' "$lib"
}

_write_env() {
	local dest=$1
	local envf="$root/.devcontainer/.env"
	local tmp
	tmp=$(mktemp)
	if [[ -f "$envf" ]]; then
		grep -v '^SANDCAT_AGENT_SANDCAT=' "$envf" >"$tmp" || true
	fi
	printf 'SANDCAT_AGENT_SANDCAT=%s\n' "$dest" >>"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$envf"
}

# Last-resort copy when the CLI/yq refresh cannot run. Prefer an existing
# stripped dest from `sandcat init` over copying live settings.
_fallback_env() {
	local dest
	dest="${HOME}/.config/sandcat/agent-sandcat/${root//\//_}"
	if [[ -d "$dest" ]]; then
		_sct_init_log "keeping existing filtered copy at $dest"
		_write_env "$dest"
		return 0
	fi
	mkdir -p "$dest"
	if [[ -d "$root/.sandcat" ]]; then
		cp -a "$root/.sandcat/." "$dest/" || true
		_sct_init_log "warning: copied .sandcat without yq secret strip"
	fi
	_write_env "$dest"
}

: >"$log"
_sct_init_log "start root=$root PATH=$PATH"

_create_cache_volumes

libdir=""
if libdir=$(_find_sct_libdir); then
	_sct_init_log "using SCT_LIBDIR=$libdir"
	# Subshell: sourced CLI libs redefine helpers and may `exit` on missing yq.
	if (
		export SCT_LIBDIR="$libdir"
		# shellcheck source=/dev/null
		source "$SCT_LIBDIR/netbird.bash"
		export_agent_sandcat_mount
	); then
		_sct_init_log "refreshed filtered .sandcat copy"
	else
		_sct_init_log "warning: CLI refresh failed; using fallback .env"
		_fallback_env
	fi
else
	_sct_init_log "sandcat CLI not found; using fallback .env"
	_fallback_env
fi

_sct_init_log "done"
exit 0
