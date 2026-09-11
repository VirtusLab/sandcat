#!/usr/bin/env bash
# Host-side helper for Dev Containers initializeCommand.
# Prepares the filtered .sandcat copy and writes .devcontainer/.env so
# compose can interpolate SANDCAT_AGENT_SANDCAT without mounting the live
# project directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

if [[ -z "${SCT_LIBDIR:-}" ]]; then
	_sandcat_bin=$(command -v sandcat 2>/dev/null || true)
	if [[ -z "$_sandcat_bin" && -x "${HOME}/.local/bin/sandcat" ]]; then
		_sandcat_bin="${HOME}/.local/bin/sandcat"
	fi
	if [[ -z "$_sandcat_bin" ]]; then
		echo "prepare-agent-sandcat-mount: sandcat CLI not found on PATH" >&2
		exit 1
	fi
	SCT_LIBDIR=$(cd "$(dirname "$_sandcat_bin")/../lib" && pwd)
	export SCT_LIBDIR
fi

# shellcheck source=/dev/null
source "$SCT_LIBDIR/netbird.bash"
export_agent_sandcat_mount
