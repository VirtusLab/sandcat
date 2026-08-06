#!/usr/bin/env bash

# shellcheck source=constants.bash
source "${BASH_SOURCE%/*}/constants.bash"
# shellcheck source=path.bash
source "${BASH_SOURCE%/*}/path.bash"
# shellcheck source=logging.bash
source "${BASH_SOURCE%/*}/logging.bash"
# shellcheck source=require.bash
source "${BASH_SOURCE%/*}/require.bash"

# Runs a command inside the capability-runtime sidecar via docker compose exec.
# Args:
#   $1 - Repository root (project directory)
#   $@ - Arguments forwarded to capability_runtime.cli inside the container
capability_compose_exec() {
	local project_dir=$1
	shift

	require docker

	local compose_file="$project_dir/.devcontainer/compose-all.yml"
	if [[ ! -f "$compose_file" ]]; then
		echo "No compose-all.yml found at $compose_file" | error
		echo "Run sandcat init --netbird --capability in this project first." >&2
		return 1
	fi

	docker compose -f "$compose_file" \
		exec -T capability-runtime python -m capability_runtime.cli "$@"
}

# Resolves the repository root for capability operator commands.
capability_project_dir() {
	find_repo_root
}

# Operator check: capability.check over the admin RPC surface.
# Args:
#   --agent <id>     Agent identity (default: devcontainer-agent)
#   --context <json> Capability context JSON object (default: {})
capability_check() {
	local agent_id="devcontainer-agent"
	local context='{}'

	while [[ $# -gt 0 ]]; do
		case $1 in
		--agent)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --agent requires a value" | error
				return 1
			fi
			agent_id="$2"
			shift 2
			;;
		--context)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --context requires a value" | error
				return 1
			fi
			context="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" | error
			return 1
			;;
		esac
	done

	local project_dir
	project_dir=$(capability_project_dir) || return 1

	capability_compose_exec "$project_dir" capability.check \
		--agent-id "$agent_id" \
		--context "$context"
}

# Operator lease: capability.lease over the admin RPC surface.
# Args:
#   --ref <capability-ref>        Capability reference (required)
#   --justification <text>        Lease justification (required)
#   --agent <id>                  Agent identity (default: devcontainer-agent)
capability_lease() {
	local agent_id="devcontainer-agent"
	local capability_ref=""
	local justification=""

	while [[ $# -gt 0 ]]; do
		case $1 in
		--ref)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --ref requires a value" | error
				return 1
			fi
			capability_ref="$2"
			shift 2
			;;
		--justification)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --justification requires a value" | error
				return 1
			fi
			justification="$2"
			shift 2
			;;
		--agent)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --agent requires a value" | error
				return 1
			fi
			agent_id="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" | error
			return 1
			;;
		esac
	done

	if [[ -z "$capability_ref" ]]; then
		echo "Missing required option: --ref" | error
		return 1
	fi
	if [[ -z "$justification" ]]; then
		echo "Missing required option: --justification" | error
		return 1
	fi

	local project_dir
	project_dir=$(capability_project_dir) || return 1

	capability_compose_exec "$project_dir" capability.lease \
		--agent-id "$agent_id" \
		--ref "$capability_ref" \
		--justification "$justification"
}

# Operator revoke: capability.revoke over the admin RPC surface.
# Args:
#   --ref <capability-ref|lease-id>  Revoke target (required)
#   --reason <text>                  Revocation reason (required)
#   --close-policy <policy>          Optional close policy override
capability_revoke() {
	local target=""
	local reason=""
	local close_policy=""

	while [[ $# -gt 0 ]]; do
		case $1 in
		--ref)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --ref requires a value" | error
				return 1
			fi
			target="$2"
			shift 2
			;;
		--reason)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --reason requires a value" | error
				return 1
			fi
			reason="$2"
			shift 2
			;;
		--close-policy)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --close-policy requires a value" | error
				return 1
			fi
			close_policy="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" | error
			return 1
			;;
		esac
	done

	if [[ -z "$target" ]]; then
		echo "Missing required option: --ref" | error
		return 1
	fi
	if [[ -z "$reason" ]]; then
		echo "Missing required option: --reason" | error
		return 1
	fi

	local project_dir
	project_dir=$(capability_project_dir) || return 1

	local -a exec_args=(
		"$project_dir" capability.revoke
		--ref "$target"
		--reason "$reason"
	)
	if [[ -n "$close_policy" ]]; then
		exec_args+=(--close-policy "$close_policy")
	fi
	capability_compose_exec "${exec_args[@]}"
}

# Operator watch: foreground capability.watch.poll loop with JSON log lines.
capability_watch() {
	local project_dir
	project_dir=$(capability_project_dir) || return 1

	capability_compose_exec "$project_dir" watch
}

# Operator demo: quick check/lease/revoke smoke against the sidecar.
# Args:
#   --agent <id>  Agent identity (default: devcontainer-agent)
capability_demo() {
	local agent_id="devcontainer-agent"

	while [[ $# -gt 0 ]]; do
		case $1 in
		--agent)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				echo "Option --agent requires a value" | error
				return 1
			fi
			agent_id="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" | error
			return 1
			;;
		esac
	done

	local project_dir
	project_dir=$(capability_project_dir) || return 1

	capability_compose_exec "$project_dir" demo --agent-id "$agent_id"
}
