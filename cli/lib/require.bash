#!/bin/bash
set -euo pipefail

: "${exitcode_expectation_failed:=168}"

# Set after a successful mikefarah probe so `sandcat init`'s many
# `require yq` calls do not spawn `yq --version` each time. `:` so a later
# `source require.bash` does not drop a cache already set in this shell.
: "${_SCT_REQUIRE_YQ_OK:=}"

# Retries yq when it dies on SIGSEGV.
#
# Some yq builds crash intermittently (measured ~0.5% of invocations on one
# aarch64 build that reports v4.53.3 but is not the upstream release binary).
# A single `sandcat init` runs ~100 sequential yq mutations under `set -e`, so
# one transient crash aborts init and leaves a half-written .devcontainer that
# looks like a generation bug. Retrying is safe: yq edits in place via
# temp-file-and-rename, so a crashed call leaves the target file untouched.
#
# stdout is buffered so a crash that already emitted partial output cannot be
# concatenated with the retry's output. Only SIGSEGV is retried; every other
# non-zero status is a real yq error and is returned unchanged.
#
# In-place edits skip the temp file: yq -i writes the result itself, and
# capturing empty stdout was doubling process overhead on the hot path.
yq() {
	local attempt status stdout_file inplace=false arg
	for arg in "$@"; do
		if [[ "$arg" == "-i" || "$arg" == "--inplace" ]]; then
			inplace=true
			break
		fi
	done

	if [[ "$inplace" == true ]]; then
		for attempt in 1 2 3; do
			status=0
			command yq "$@" || status=$?
			if [[ "$status" -ne 139 ]]; then
				return "$status"
			fi
		done
		return "$status"
	fi

	stdout_file=$(mktemp)

	for attempt in 1 2 3; do
		status=0
		command yq "$@" >"$stdout_file" || status=$?
		if [[ "$status" -ne 139 ]]; then
			break
		fi
		: >"$stdout_file"
	done

	cat "$stdout_file"
	rm -f "$stdout_file"
	return "$status"
}

# Ensures a command is available
# Args:
#   $1 - The command name to require
# Returns:
#   0 if command is available or successfully shimmed, non-zero otherwise
require() {
	local -r cmd="$1"

	if [[ "$cmd" == "yq" ]]; then
		if [[ -n "${_SCT_REQUIRE_YQ_OK:-}" ]]; then
			return 0
		fi

		# yq is wrapped by the shell function above, so command -v would
		# report it as present even with no binary installed.
		if ! type -P yq &>/dev/null
		then
			>&2 echo "$0: yq required"
			return "$exitcode_expectation_failed"
		fi

		# Two unrelated tools share the name `yq`: Mike Farah's Go yq
		# (what sandcat uses) and Python yq (kislyuk/yq), which is what
		# `apt install yq` ships on Debian/Ubuntu. Probe the PATH binary
		# directly so the retry wrapper cannot shadow --version.
		if ! command yq --version 2>&1 | grep -q mikefarah
		then
			>&2 echo "$0: sandcat needs Mike Farah's yq (https://github.com/mikefarah/yq); a different 'yq' is on PATH."
			>&2 echo "On Debian/Ubuntu, 'apt install yq' installs the incompatible Python yq (kislyuk/yq)."
			>&2 echo "Install Mike Farah's yq from https://github.com/mikefarah/yq/#install (e.g. 'snap install yq')."
			return "$exitcode_expectation_failed"
		fi
		_SCT_REQUIRE_YQ_OK=1
		return 0
	fi

	if ! command -v "$cmd" &>/dev/null
	then
		>&2 echo "$0: $cmd required"
		return "$exitcode_expectation_failed"
	fi
}
